open Core_kernel.Std
open Bap_types.Std
open Bap_image_std
open Bap_disasm_std
open Bap_ir


(* A note about lifting call instructions.

   We're labeling calls with an expected continuation, that should be
   derived from the BIL. But instead we lift calls in a rather
   speculative way, thus breaking the abstraction of the BIL, that
   desugars calls into two pseudo instructions:

   <update return address to next instruction>
   <jump to target>

   A correct way of doing things would be to find a live write to the
   place that is used to store return address (ABI specific), and put
   this expression as an expected return address (aka continuation).

   But a short survey into existing instruction sets shows, that call
   instructions doesn't allow to store something other then next
   instruction, e.g., `call` in x86, `bl` in ARM, `jal` in MIPS,
   `call` and `jumpl` in SPARC (althought the latter allows to choose
   arbitrary register to store return address). That's all is not to
   say, that it is impossible to encode a call with return address
   different from a next instruction, that's why it is called a
   speculation.
*)

type linear =
  | Label of tid
  | Instr of Ir_blk.elt

(* we're very conservative here *)
let has_side_effect e scope = (object inherit [bool] Bil.visitor
  method! enter_load  ~mem:_ ~addr:_ _e _s _r = true
  method! enter_store ~mem:_ ~addr:_ ~exp:_ _e _s _r = true
  method! enter_var v r = r || Bil.is_assigned v scope
end)#visit_exp e false

(** This optimization will inline temporary variables that occurrs
    inside the instruction definition if the right hand side of the
    variable definition is either side-effect free, or another
    variable, that is not changed in the scope of the variable definition. *)
let inline_variables stmt =
  let rec loop ss = function
    | [] -> List.rev ss
    | Bil.Move _ as s :: [] -> loop (s::ss) []
    | Bil.Move (x, Bil.Var y) as s :: xs when Var.is_tmp x ->
      if Bil.is_assigned y xs || Bil.is_assigned x xs
      then loop (s::ss) xs else
        let xs = Bil.substitute (Bil.var x) (Bil.var y) xs in
        loop ss xs
    | Bil.Move (x, y) as s :: xs when Var.is_tmp x ->
      if has_side_effect y xs || Bil.is_assigned x xs
      then loop (s::ss) xs
      else loop ss (Bil.substitute (Bil.var x) y xs)
    | s :: xs -> loop (s::ss) xs in
  loop [] stmt

let optimize =
  List.map ~f:Bil.fixpoint [
    Bil.prune_unreferenced;
    Bil.fold_consts;
    Bil.normalize_negatives;
    inline_variables;
  ]
  |> List.reduce_exn ~f:Fn.compose
  |> Bil.fixpoint

let fall_of_block block =
  Seq.find_map (Block.dests block) ~f:(function
      | `Block (b,`Fall) -> Some b
      | _ -> None)

let label_of_fall block =
  Option.map (fall_of_block block) ~f:(fun blk ->
      Label.indirect Bil.(int (Block.addr blk)))

let annotate_insn term insn = Term.set_attr term Disasm.insn insn
let annotate_addr term addr = Term.set_attr term Disasm.insn_addr addr


let linear_of_stmt ?addr fall insn stmt : linear list =
  let (~@) t = match addr with
    | None -> t
    | Some addr -> annotate_addr (annotate_insn t insn) addr in
  let goto ?cond id =
    Ir_blk.Jmp ~@(Ir_jmp.create_goto ?cond (Label.direct id)) in
  let jump ?cond exp =
    let target = Label.indirect exp in
    let tail = if cond = None then [] else
        match Lazy.force fall with
        | None -> []
        | Some fall -> [Ir_jmp.create_goto fall] in
    if Insn.is_return insn
    then Ir_jmp.create_ret ?cond target :: tail
    else if Insn.is_call insn
    then [
      Ir_jmp.create_call ?cond
        (Call.create ?return:(Lazy.force fall) ~target ())
    ] else Ir_jmp.create_goto ?cond target :: tail in
  let jump ?cond exp =
    List.map (jump ?cond exp) ~f:(fun j -> Instr (Ir_blk.Jmp ~@j)) in
  let cpuexn ?cond n =
    let next = Tid.create () in [
      Instr (Ir_blk.Jmp ~@(Ir_jmp.create_int ?cond n next));
      Label next] in

  let rec linearize = function
    | Bil.Move (lhs,rhs) ->
      [Instr (Ir_blk.Def ~@(Ir_def.create lhs rhs))]
    | Bil.If (cond, [],[]) -> []
    | Bil.If (cond,[],no) -> linearize Bil.(If (lnot cond, no,[]))
    | Bil.If (cond,[Bil.CpuExn n],[]) -> cpuexn ~cond n
    | Bil.If (cond,[Bil.Jmp exp],[]) -> jump ~cond exp
    | Bil.If (cond,yes,[]) ->
      let yes_label = Tid.create () in
      let tail = Tid.create () in
      Instr (goto ~cond yes_label) ::
      Instr (goto tail) ::
      Label yes_label ::
      List.concat_map yes ~f:linearize @
      Instr (goto tail) ::
      Label tail :: []
    | Bil.If (cond,yes,no) ->
      let yes_label = Tid.create () in
      let no_label = Tid.create () in
      let tail = Tid.create () in
      Instr (goto ~cond yes_label) ::
      Instr (goto no_label) ::
      Label yes_label ::
      List.concat_map yes ~f:linearize @
      Instr (goto tail) ::
      Label no_label ::
      List.concat_map no ~f:linearize @
      Instr (goto tail) ::
      Label tail :: []
    | Bil.Jmp exp -> jump exp
    | Bil.CpuExn n -> cpuexn n
    | Bil.Special _ -> []
    | Bil.While (cond,body) ->
      let header = Tid.create () in
      let tail = Tid.create () in
      let finish = Tid.create () in
      Instr (goto tail) ::
      Label header ::
      List.concat_map body ~f:linearize @
      Instr (goto tail) ::
      Label tail ::
      Instr (goto ~cond header) ::
      Instr (goto finish) ::
      Label finish :: [] in
  linearize stmt

let lift_insn ?addr fall init insn =
  List.fold (optimize @@ Insn.bil insn) ~init ~f:(fun init stmt ->
      List.fold (linear_of_stmt ?addr fall insn stmt) ~init
        ~f:( fun (bs,b) -> function
            | Label lab ->
              Ir_blk.Builder.result b :: bs,
              Ir_blk.Builder.create ~tid:lab ()
            | Instr elt ->
              Ir_blk.Builder.add_elt b elt; bs,b))

let blk block : blk term list =
  List.fold (Block.insns block) ~init:([],Ir_blk.Builder.create ())
    ~f:(fun init (mem,insn) ->
        let addr = Memory.min_addr mem in
        lift_insn ~addr (lazy (label_of_fall block)) init insn) |>
  fun (bs,b) -> match List.rev (Ir_blk.Builder.result b :: bs) with
  | [] -> []
  | b :: bs -> Term.set_attr b Disasm.block (Block.addr block) :: bs

(* extracts resolved calls from the blk *)
let call_of_blk blk =
  Term.to_sequence jmp_t blk |>
  Seq.find_map ~f:(fun jmp -> match Ir_jmp.kind jmp with
      | Int _ | Goto _ | Ret _ -> None
      | Call call -> match Call.target call with
        | Direct _ -> None
        | Indirect (Bil.Int addr) -> Some addr
        | Indirect _ -> None)

let resolve_jmp addrs jmp =
  let update_kind jmp addr make_kind =
    Option.value_map ~default:jmp
      (Hashtbl.find addrs addr)
      ~f:(fun id -> Ir_jmp.with_kind jmp (make_kind id)) in
  match Ir_jmp.kind jmp with
  | Ret _ | Int _ -> jmp
  | Goto (Indirect (Bil.Int addr)) ->
    update_kind jmp addr (fun id -> Goto (Direct id))
  | Goto _ -> jmp
  | Call call ->
    let jmp,call = match Call.target call with
      | Indirect (Bil.Int addr) ->
        let new_call = ref call in
        let jmp = update_kind jmp addr
            (fun id ->
               new_call := Call.with_target call (Direct id);
               Call !new_call) in
        jmp, !new_call
      | _ -> jmp,call in
    match Call.return call with
    | Some (Indirect (Bil.Int addr)) ->
      update_kind jmp addr
        (fun id -> Call (Call.with_return call (Direct id)))
    | _ -> jmp

let unbound _ = true



let lift_sub ?(bound=unbound) entry =
  let addrs = Addr.Table.create () in
  let rec recons acc b =
    let addr = Block.addr b in
    if not (Hashtbl.mem addrs addr) && bound addr then
      let bls = blk b in
      Option.iter (List.hd bls) ~f:(fun blk ->
          Hashtbl.add_exn addrs ~key:addr ~data:(Term.tid blk));
      Seq.fold (Block.succs b) ~init:(acc @ bls) ~f:recons
    else acc in
  let blks = recons [] entry in
  let n = let n = List.length blks in Option.some_if (n > 0) n in
  let sub = Ir_sub.Builder.create ?blks:n () in
  List.iter blks ~f:(fun blk ->
      Ir_sub.Builder.add_blk sub
        (Term.map jmp_t blk ~f:(resolve_jmp addrs)));
  let sub = Ir_sub.Builder.result sub in
  Term.set_attr sub subroutine_addr (Block.addr entry)

let program symtab =
  let b = Ir_program.Builder.create () in
  let addrs = Addr.Table.create () in
  Seq.iter (Symtab.to_sequence symtab) ~f:(fun fn ->
      let addr = Block.addr (Symtab.entry_of_fn fn) in
      let in_fun = unstage (Symtab.create_bound symtab fn) in
      let entry = Symtab.entry_of_fn fn in
      let sub = lift_sub ~bound:in_fun entry in
      let name = Symtab.name_of_fn fn in
      Ir_program.Builder.add_sub b (Ir_sub.with_name sub name);
      Hashtbl.add_exn addrs ~key:addr ~data:(Term.tid sub));
  let program = Ir_program.Builder.result b in
  Term.map sub_t program
    ~f:(Term.map blk_t ~f:(Term.map jmp_t ~f:(resolve_jmp addrs)))


let sub = lift_sub

let insn insn =
  lift_insn (lazy None) ([], Ir_blk.Builder.create ()) insn |>
  function (bs,b) -> List.rev (Ir_blk.Builder.result b :: bs)
