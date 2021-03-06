open Packet
open SDN_Types
open Network_Common
open Merlin_TC
open Merlin_NFA
open Merlin_Util
open Merlin_Types
open Merlin_Error
open Merlin_Pretty
open Merlin_Globals
open Merlin_BigGraph
open Merlin_Dictionaries

module NK = NetKAT_Types

let tag_cell = ref 0

let fresh_tag () : int =
  incr tag_cell ; !tag_cell

let qmap = Hashtbl.create 32

let get_map () : ((switchId * portId), Int32.t) Hashtbl.t =
  qmap

let fresh_queue sw port =
  let oldq =
    try
      Hashtbl.find qmap (sw,port)
    with Not_found -> 0l in
  let newq = Int32.succ oldq in
  Hashtbl.replace qmap (sw,port) newq;
  newq

let get_shortest_path t s d tbl len =
  let open Node in
  let src = VertexHash.find tbl s in
  let dst = VertexHash.find tbl d in

  let gather_prevs previous =
    let rec mk_path current =
      if current = src then NPH.replace nodes_to_paths (src,src) [src] else
        let prev = VertexHash.find previous current in
        let p = try List.rev (NPH.find nodes_to_paths (src,prev))
          with Not_found ->
            mk_path prev;
            List.rev (NPH.find nodes_to_paths (src,prev))
        in
        let p' = current::p in
        NPH.replace nodes_to_paths (src,current) (List.rev p')
    in

    VertexHash.iter (fun node _ ->
      if node = src then ()
      else if NPH.mem nodes_to_paths (src,node) then ()
      else mk_path node
    ) previous
  in

  let p =
    if src = dst then [src] else
      try NPH.find nodes_to_paths (src,dst)
      with Not_found ->
        let paths = NetPath.all_shortest_paths t src in
        gather_prevs paths;
        print_paths nodes_to_paths ;
        NPH.find nodes_to_paths (src,dst)
  in

  (s,p,d)

module Flow = struct

  let mk_tc (pr:pred) (max:int64) : string =
    let r = Rate(0L,max) in
    let cmds = TC.tccmds_of_spec pr r in
    let tcs = list_intercalate TC.string_of_tccmd "\n" cmds in
    tcs

  let mk_step (tag:int) (pred:pred) (fwd:forward) =
    let pred_and = match fwd.predicate with
      | Some p -> And(pred, p)
      | None -> pred in
    let in_port_and p = match fwd.in_port with
      | Some i -> And(Test(NK.(Location(Physical i))), p)
      | None -> p in
    let _,devid = fwd.device in
    let out_port = match fwd.out_port with
      | None -> raise Unspecified_port
      | Some i -> i in
    let out_action, qcopt = match fwd.min with
      | Some (min) ->
        let outq = fresh_queue devid out_port in
        let action = Enqueue(out_port, outq) in
        (* TODO(rjs) should this be max value? I think it should be capacity *)
        (action, Some( QConf(devid, out_port, outq, min, Int64.max_int)))
      | None ->
        (Output(Physical out_port), None) in
    let pred',actions = match fwd.in_hop, fwd.out_hop with
      | Ingress,Egress ->
        (And (And(Test(NK.Switch devid),
                  in_port_and pred_and),
              Test(NK.Vlan !dl_vlan)),
         [out_action])
      | Ingress,Intermediate ->
        (* first hop *)
        (And(Test(NK.Switch devid), pred_and),
         [Modify (SetVlan (Some tag)); out_action])
      | Intermediate, Intermediate ->
        (And (Test(NK.Switch devid),
              Test(NK.Vlan tag)),
         [out_action])
      | Intermediate, Egress ->
        (* last hop *)
        (*  0xFFFF signals the SDN abstraction layer to strip the Vlan tag. *)
        let pr = And (Test(NK.Switch devid),
                      Test(NK.Vlan tag)) in
        let pr' = match fwd.predicate with
          | Some p -> And (p, pr)
          | None -> pr in
        (pr', [Modify (SetVlan (Some !dl_vlan)); out_action])
      | i,o ->
        (pred, []) in
        (*raise (Invalid_hop_sequence(i,o)) in*)
    ((pred', actions, devid), qcopt)


  (* TODO(rjs)  topo_node in fws is node *)
  (* TODO(rjs)  Is this dead code now? *)
  let mk_click (t:topo) (is: (vertex * string list) list) : (Packet.nwAddr * string) list =
    List.map (fun (n, ls) ->
      let label = Net.Topology.vertex_to_label t n in
      let ip = Node.ip label in
      let clicks = list_intercalate Merlin_Click.to_click "\n" ls in
      (ip, clicks)
    ) is


  let to_machine (t:topo) ((pred,path):flow)
      : (step list * swqconf list * (nwAddr * string) list * (Packet.nwAddr * string) list ) =
    let tag = fresh_tag () in
    List.fold_left (fun (ofs,qcs,tcs,clicks) fwd ->
      let open Node in
      let devtype, devid = fwd.device in

      let clicks' =
        match fwd.functions with
        | Some fns ->
          let label = Net.Topology.vertex_to_label t fwd.topo_vertex in
          let ip = Node.ip label in
          let click_str = list_intercalate Merlin_Click.to_click "\n" fns in
          let click =  (ip, click_str) in
          click::clicks
        | None -> clicks
      in

      match devtype with
      | Host ->
        let (ofs,qcs,tcs) =
          begin
            match fwd.out_hop,fwd.max with
            | Ingress, Some(max) ->
              let label = Net.Topology.vertex_to_label t fwd.topo_vertex in
              let ip = Node.ip label in
              let tccmd = (ip, mk_tc pred max) in
              (ofs,qcs,tccmd::tcs)
            | _ -> (ofs,qcs,tcs)
          end
        in
        (ofs,qcs,tcs,clicks')
      | Switch ->
        let step, qcopt = mk_step tag pred fwd in
        begin
          match qcopt with
          | Some qc -> (step::ofs, qc::qcs, tcs, clicks)
          | None -> (step::ofs, qcs, tcs, clicks')
        end
      | Middlebox ->
        Printf.printf "==> to_machine, devtype == middlebox\n";
        (ofs,qcs,tcs,clicks')

    ) ([], [], [], []) path

end

module Gather = struct
  let steps (ofls : (pred * action list * switchId)  list)
      : (switchId, (pred * action list) list) Hashtbl.t =
    let tbl = Hashtbl.create 100 in
    List.iter (fun (p,a,s) ->
      let ls =
        try Hashtbl.find tbl s
        with Not_found -> [] in
      Hashtbl.replace tbl s ((p,a)::ls)
    ) ofls;
    tbl

  let queues_by_switch (qcls : swqconf list)
      : (switchId, swqconf list) Hashtbl.t =
    let swtbl = Hashtbl.create 100 in
    List.iter (fun qc ->
      let QConf(sw,_,_,_,_) = qc in
      let current = try Hashtbl.find swtbl sw
        with Not_found -> [] in
      Hashtbl.add swtbl sw (qc::current)
    ) qcls;
    swtbl

  let queue_configs (qcls : swqconf list)
      : (switchId, (portId, (queueId,(int64*int64)) Hashtbl.t) Hashtbl.t) Hashtbl.t =
    let swtbl = Hashtbl.create 100 in
    List.iter (fun qc ->
      let QConf(sw,port,qid,min,max) = qc in
      let porttbl =
        try Hashtbl.find swtbl sw
        with Not_found -> let tbl = Hashtbl.create 64 in
                          Hashtbl.add swtbl sw tbl; tbl in
      let qtbl =
        try Hashtbl.find porttbl port
        with Not_found -> let tbl = Hashtbl.create 8 in
                          Hashtbl.add porttbl port tbl; tbl in
      Hashtbl.replace qtbl qid (min,max)
    ) qcls;
    swtbl

  let tcs (tcls : (Packet.nwAddr * string) list)
      : (Packet.nwAddr, string list) Hashtbl.t =
    let tbl = Hashtbl.create (List.length tcls) in
    List.iter (fun (ip,tc) ->
      let ls =
        try Hashtbl.find tbl ip
        with Not_found -> [] in
      Hashtbl.replace tbl ip (tc::ls)
    ) tcls;
    tbl
end

module type TOPOINFO = sig
  val topo : topo
  val hostless : topo
  val size : int
end

module Forward(T:TOPOINFO) = struct


  let from_path (p:(portId * hop * vertex * portId * hop) list) min max :
      forward list =
    let open Node in
    let len = List.length p in
    let _,fwds = List.fold_left (fun (i,acc) (inp,ih,n,outp,oh) ->
      let label = Net.Topology.vertex_to_label T.topo  n in
      let fwd_part = { device = (Node.device label, Node.id label)
                     ; topo_vertex = n ; min = min ; max = max; predicate = None
                     ; in_port = Some inp ; out_port = Some outp
                     ; in_hop = Ingress ; out_hop = Egress
                     ; functions = None ; } in
      if i = 0 then
        let oh = if (List.length p) = 1 then Egress else Intermediate in
        let fwd = {fwd_part with in_hop = Ingress ; out_hop = oh} in
        (i+1,fwd::acc)
      else if i = (len - 1) then
        let fwd = {fwd_part with in_hop = Intermediate ; out_hop = Egress} in
        (i+1,fwd::acc)
      else
        let fwd = {fwd_part with in_hop = Intermediate ; out_hop = Intermediate} in
        (i+1,fwd::acc)
    ) (0,[]) p in
    List.rev fwds

  let from_vertexpath ((src,path,dst):(vertex * vertex list * vertex)) min max : forward list =
    let open Node in
    let open Net.Topology in
    let open Merlin_Topology in

    let src' = map_vertex src T.hostless T.topo in
    let dst' = map_vertex dst T.hostless T.topo in
    let pathhead = map_vertex (List.hd path) T.hostless T.topo in
    let pathend = (List.length path ) - 1 in

    let src_label = vertex_to_label T.topo src' in
    let src_edge = find_edge T.topo src' pathhead in
    let _,srcport = edge_src src_edge in
    let start = {device = (Node.device src_label,Node.id src_label);
                 in_port = None; out_port = Some srcport;
                 min = min; max = max;
                 in_hop = Nohop; out_hop = Ingress ; topo_vertex = src' ;
                 predicate = None ; functions = None;
                } in

    let _,fwds,last = List.fold_left (fun (i,acc,last) node ->
      let node' = map_vertex node T.hostless T.topo in
      let label = vertex_to_label T.topo node' in
      match (Node.device label) with
      | Switch
      | Host ->
        let sw = Node.id label in
        let nt = Node.device label in
        let prev = if i=0 then src else List.nth path (i-1) in
        let next = if i=pathend then dst else List.nth path (i+1) in

        let prev' = map_vertex prev T.hostless T.topo in
        let next' = map_vertex next T.hostless T.topo in

        let inedge = find_edge T.topo prev' node' in
        let outedge = find_edge T.topo node' next' in

        let ih = if i = 0 then Ingress else Intermediate in
        let oh = if i = pathend then Egress else Intermediate in
        let _,ip = edge_dst inedge in
        let _,op = edge_src outedge in

        let fwd = {in_port = Some ip; device = (nt,sw);
                   out_port = Some op; min = min; max = max;
                   in_hop = ih; out_hop = oh ; topo_vertex = node' ;
                   predicate = None ; functions = None;
                  } in
        (i+1, fwd::acc, node)
      | _ ->
        (i+1, acc,node)
    ) (0,[start],src) path in

    let last' = map_vertex last T.hostless T.topo in
    let dst_edge = find_edge T.topo last' dst' in
    let dst_label = vertex_to_label T.topo dst' in
    let _,ip = edge_dst dst_edge in
    let stop = {device = (Node.device dst_label,Node.id dst_label);
                 in_port = Some ip; out_port = None ;
                 min = min; max = max;
                 in_hop = Egress; out_hop = Nohop ; topo_vertex = dst' ;
                 predicate = None ; functions = None;
                } in
    List.rev (stop::fwds)

  let from_crosspath (path:CrossGraph.E.t list) p_source p_sink min max : forward list =
    let path' = List.fold_left (fun acc (src,dst) ->
      let open Node in
      let (_,p_src) = src in
      let (_,p_dst) = dst in
      let e = Net.Topology.find_edge T.topo p_src p_dst in

      match acc with
      | [] ->
        let src,srcport = Net.Topology.edge_src e in
        let dst,dstport = Net.Topology.edge_dst e in
        [ (dstport , Egress, dst, 0l, Nohop)
        ; (0l, Nohop, src, srcport, Ingress)]
      | (inp,inh,srcnode,outp,outh)::tl ->
        let _,srcport = Net.Topology.edge_src e in
        let dstnode,dstport = Net.Topology.edge_dst e in
        let src = (inp,inh,srcnode, srcport, Intermediate) in
        let dst = (dstport,Egress,dstnode, 0l,Nohop) in
        dst::src::tl
    ) [] path in
    from_path path' min max

  let from_regex (r:regex) (tbl:vertex VertexHash.t) min max : forward list =
    let mk_nodepath (path: string list) : (vertex * vertex list * vertex) =
      let dst = ref "" in
      let rec aux p = match p with
        | [] -> []
        | [n] -> dst := n; []
        | n::ns -> let node = LocationHash.find location_to_node n in
                   node::(aux ns) in
      let src = LocationHash.find location_to_node (List.hd path) in
      let path' = List.rev(aux (List.tl path)) in
      let dst = LocationHash.find location_to_node !dst in
      (src,path',dst) in
    let rec mk_complete_path (r:regex) = match r with
      | Char(c) -> let (l,r) = SymbolHash.find symbol_to_code c in [l]
      | Cat(r1,r2) -> (mk_complete_path r1)@(mk_complete_path r2)
      | Group(r) -> mk_complete_path r
      | _ -> raise (Unrealizable_path r) in
    if (is_complete_path r) then
      let node_path = mk_nodepath (mk_complete_path r) in
      from_vertexpath node_path min max
    else if (is_any_path r) then begin
      let s,d = get_endpoints r in
      let src = LocationHash.find location_to_node s in
      let dst = LocationHash.find location_to_node d in
      let r = from_vertexpath (get_shortest_path T.hostless src dst tbl T.size)
        min max in
      r
    end
    else
      let r' = Merlin_Preprocess.pad_regex r start_symbol end_symbol in
      let t',p_src,p_dst = Merlin_Topology.pad_topo T.topo in
      let cross_start = Merlin_Time.time () in
      let g,n_src,n_dst = CrossGraph.cross r' T.topo in
      let cross_stop = Merlin_Time.time () in
      Printf.printf "Cross time: %Ld (nsec)\n" (Int64.sub cross_stop cross_start);
      Printf.printf "Cross time: %Ld (sec)\n" (Merlin_Time.to_secs (Int64.sub cross_stop cross_start));
      let src = (n_src,p_src) in
      let dst = (n_dst,p_dst) in
      let sp_start = Merlin_Time.time () in
      let path = CrossGraph.shortest_path g src dst in
      let sp_stop = Merlin_Time.time () in
      Printf.printf "Shortest path time: %Ld (nsec)\n" (Int64.sub sp_stop sp_start);
      Printf.printf "Shortest path time: %Ld (sec)\n" (Merlin_Time.to_secs (Int64.sub sp_stop sp_start));
      from_crosspath path p_src p_dst min max
end

let from_flows (topo:topo) (fs: flow list)
    : (step list * swqconf list * (nwAddr * string) list * (Packet.nwAddr * string) list) =
  let start_time = Merlin_Time.time () in
  let steps, qcs, tcs, clicks = List.fold_left (fun (s,q,t,c) flow ->
    let steps, qcs, tcs, clicks = Flow.to_machine topo flow in
    steps::s, qcs::q, tcs::t,clicks::c
  ) ([],[],[],[]) fs in
  Merlin_Stats.stepgen := Int64.sub (Merlin_Time.time ()) start_time;
  (List.flatten steps, List.flatten qcs, List.flatten tcs, List.flatten clicks)
