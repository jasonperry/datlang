(** Code generation module *)

open Common
open Ast
open Types
open Symtable1
open Llvm

exception CodegenError of string

(* Trying not to make a new context per module. OK so far. *)
let context = global_context() 
let float_type = double_type context
let int_type = i32_type context
let bool_type = i1_type context
let void_type = void_type context (* may end up not using these. *)
let nulltag_type = i8_type context

(* Implement comparison for typetag so we can make a map of them. *)
module TypeTag = struct
  type t = typetag
  let compare t1 t2 =
    String.compare (typetag_to_string t1) (typetag_to_string t2)
end

module TtagMap = Map.Make(TypeTag)

(* dressed-up type environment to store field offsets as well. *)
module Lltenv = struct
  type fieldmap = (int * typetag) StrMap.t
  type tagmap = int TtagMap.t (* map a subtype tag to the union index. *)
  (* TypeMap.t: (module, typename) -> value *)
  (* Can I just take a typetag and pull in_module and classname out of
     that, so I don't have to awkwardly pass pairs? Should be okay as
     long as this is used only for looking up classes? *)
  type t = (lltype * fieldmap) TypeMap.t  
  let empty: t = TypeMap.empty
  let add strpair (llty, fmap) map = TypeMap.add strpair (llty, fmap) map
  (* Return just the LLVM type for a given type name. *)
  let find_lltype tkey tmap = fst (TypeMap.find tkey tmap)
  let find_class_lltype tclass tmap =
    fst (TypeMap.find (tclass.in_module, tclass.classname) tmap)
  let find_lltype_opt tkey tmap =
    Option.map fst (TypeMap.find_opt tkey tmap)
  (* Get the offset of a record field. *)
  let find_field tkey fieldname tmap =
    let (_, fmap) = TypeMap.find tkey tmap in
    StrMap.find fieldname fmap
end

(** Process a classData to generate a new llvm base type *)
let rec gen_lltype context
      (types: classData TypeMap.t) (lltypes: Lltenv.t) layout (cdata: classData) =
  match (cdata.in_module, cdata.classname) with
  (* need special case for primitive types. Should handle this with some
   * data structure, so it's consistent among modules *)
  | ("", "Void") -> void_type, StrMap.empty
  | ("", "Bool") -> bool_type, StrMap.empty
  | ("", "Int") -> int_type, StrMap.empty
  | ("", "Float") -> float_type, StrMap.empty
  | ("", "String") -> pointer_type (i8_type context), StrMap.empty
  | ("", "NullType") -> nulltag_type, StrMap.empty (* causes crash? *) 
  | _ ->
     if cdata.fields <> [] then (
       (* Record type. Generate list of types from record fields *)
       let tlist =
         List.mapi (fun i fi ->
             let mname, tname = fi.fieldtype.modulename, fi.fieldtype.typename in
             let basetype = match Lltenv.find_lltype_opt
                                    (mname, tname) lltypes with
               | Some basetype -> basetype
               (* what happens if the type is recursive?  
                * I believe its type will be generated and added separately.
                * I hope it doesn't confuse LLVM if the same named type is
                * generated twice. *)
               | None -> fst (gen_lltype context types lltypes layout
                                (TypeMap.find (mname, tname) types))
             in if fi.fieldtype.array
              then (array_type basetype 0, i, fi.fieldtype)
                else (basetype, i, fi.fieldtype)
           ) cdata.fields
       in
       (* Create a mapping from field names to offsets (and types). *)
       let field_offsets =
         List.fold_left (fun fomap (_, i, ftype) ->
           StrMap.add ((List.nth cdata.fields i).fieldname) (i, ftype) fomap
           ) StrMap.empty tlist in
       (* Create named struct type *)
       let typename = cdata.in_module ^ "::" ^ cdata.classname in
       let structtype = named_struct_type context typename in
       (* Don't know if we will want packed structs in the future *)
       struct_set_body structtype (List.map (fun (lty, _, _) -> lty) tlist
                                 |> Array.of_list) false;
       (structtype, field_offsets)
     ) else if (cdata.subtypes <> []) then (
       (* must be a union type. *)
       let maxsize =
         List.fold_left (fun max subtype ->
             let lltype = Lltenv.find_class_lltype subtype.tclass lltypes in
             let typesize = Llvm_target.DataLayout.abi_size
                              lltype layout in
             if typesize > max then typesize else max
           ) (Int64.of_int 0) cdata.subtypes
       in 
       (* do I have to recursively add the subtypes too? Won't they already
        *  be defined? Maybe not in a specific incarnation. What's the 
        * difference with record fields? *)
       
       print_endline ("Max subtype size: " ^ Int64.to_string maxsize);
       failwith "almost there"
     (* Generate an integer to subtype map *)
        (* struct_type 
                         [| uniontag_type; array_type (i8_type * nbytes) |] *)
     ) else
       failwith ("BUG: unknown class type " ^ cdata.classname ^ "in codegen")

(** Use a type tag to generate the LLVM type from the base type. *)
let ttag_to_llvmtype lltypes ttag =
  (* find_opt only for debugging. *)
  (* I think we will look up the field offsets elsewhere *)
  match Lltenv.find_lltype_opt (ttag.modulename, ttag.typename) lltypes with
  | None -> failwith ("BUG: no lltype found for " ^ ttag.modulename
                      ^ "::" ^ ttag.typename)
  | Some basetype ->
     let with_null =
       if ttag.nullable then
         struct_type context [| nulltag_type; basetype |]
       else basetype in
     if ttag.array then
       array_type with_null 0  (* a stub for now, to give the idea. *)
     else
       with_null


(** Generate LLVM allocation for a varexp, traversing fields *)
(* Seems I need to do this once to get the load from the field offset. 
 * BUT after that I could store the field alloca back in the symtable?! *)
let gen_varexp_alloca varentry fieldlist lltypes builder =
  match varentry.addr with 
  | None -> failwith ("BUG: gen_varexp_alloca: alloca address not present for "
                      ^ varentry.symname)
  | Some alloca ->
     (* traverse record fields to generate final alloca for store. *)
     (* BIG IDEA: symtable for record itself, only tenv for subfields.
      *  Hope it works because you only need the offset, not the address. *)
     let rec get_field_alloca flds parentty alloca =
       match flds with
       | [] -> alloca
       | fld::rest -> 
          (* Get just the class of parent type so we can find its field info. *)
          (* Later: handle array indexing. *)
          let ptypekey = (parentty.modulename, parentty.typename) in
          (* Look up field offset in Lltenv, emit gep *)
          let offset, fieldtype = Lltenv.find_field ptypekey fld lltypes in
          let alloca = build_struct_gep alloca offset "fld" builder in
          (*  Propagate field's typetag to next iteration *)
          get_field_alloca rest fieldtype alloca
     in
     get_field_alloca fieldlist varentry.symtype alloca


(** Wrap a value in an outer type. Used for passing a specific case of a 
  * union type (just nullable at first) *)
let promote_value the_val (* valtype *) outertype builder lltypes =
  (* for now, just assume the outer type is nullable version. *)
  if not (outertype.nullable) then
    failwith "BUG: can only promote value to nullable type for now"
  else
    let alloca = build_alloca
                   (ttag_to_llvmtype lltypes outertype)
                   "promotedaddr" builder in
    let tagval =
      (* It seems I can get away with checking just the LLVM type here. *)
      if is_null the_val then const_int nulltag_type 0
      else const_int nulltag_type 1 in
    let tagaddr = build_struct_gep alloca 0 "tagaddr" builder in
    ignore (build_store tagval tagaddr builder);
    (* Only build a store for the value if it's not null. *)
    if not (is_null the_val) then ( 
      let valaddr = build_struct_gep alloca 1 "valaddr" builder in
      ignore (build_store the_val valaddr builder));
    (* Now reload the whole thing for the result. *)
    build_load alloca "promotedval" builder


(** Generate LLVM code for an expression *)
let rec gen_expr the_module builder syms lltypes (ex: typetag expr) = 
  match ex.e with
  | ExpConst NullVal -> const_int nulltag_type 0 (* maybe used now *)
  | ExpConst (BoolVal b) -> const_int bool_type (if b then 1 else 0)
  | ExpConst (IntVal i) -> const_int int_type i
  | ExpConst (FloatVal f) -> const_float float_type f
  | ExpConst (StringVal s) ->
     (* It will build the instruction /and/ return the ptr value *)
     build_global_stringptr s "sconst" builder
  (* stmtDecl will create new symtable entry, this will get it. *)
  | ExpVar (varname, fields) -> (
    (* let varstr = String.concat "." (varname::fields) in *)
    let (entry, _) = Symtable.findvar varname (*varstr*) syms in
    let alloca = gen_varexp_alloca entry fields lltypes builder in
    build_load alloca varname builder
  )
  | ExpRecord _ (* fieldlist *) ->
     (* Record init expr will be desugared to a list of assignments. *)
     (* Do I need the type hint here, like I do in the analyzer? *)
     (* look up each field in symtable to get its address, 
      * put in a list, sort by the index, remove the index? *)
     failwith "BUG Record codegen not implemented in non-assignment context"
  | ExpUnop (op, e1) -> (
    (* there are const versions of the ops I could try to put in later, 
     * for optimization. *)
    let e1val = gen_expr the_module builder syms lltypes e1 in
    if e1.decor = int_ttag then 
      match op with
      (* type checker should catch negating an unsigned. *)
      | OpNeg -> build_neg e1val "inegtemp" builder
      | OpBitNot -> build_not e1val "bitnottemp" builder
      | _ -> failwith "BUG: Codegen type error in unary op (int)"
    else if e1.decor = float_ttag then
      match op with
      | OpNeg -> build_fneg e1val "fnegtemp" builder
      | _ -> failwith "BUG: Codegen type error in unary op (float)"
    else if e1.decor = bool_ttag then 
      match op with 
      | OpNot -> build_not e1val "boolnottemp" builder
      | _ -> failwith "BUG: Codegen type error in unary op (bool)"
    else
      failwith "BUG: Unknown type in unary op"
  )
  | ExpBinop (e1, op, e2) -> (
    let e1val = gen_expr the_module builder syms lltypes e1 in
    let e2val = gen_expr the_module builder syms lltypes e2 in
    (* TODO: look up operator in classdata. Probably a variant type 
     * for a built-in versus method. Though only codegen knows the instruction. *)
    if e1.decor = int_ttag then
      match op with
      | OpTimes -> build_mul e1val e2val "imultemp" builder
      | OpDiv -> build_sdiv e1val e2val "sdivtemp" builder
      | OpPlus -> build_add e1val e2val "iaddtemp" builder
      | OpMinus -> build_sub e1val e2val "isubtemp" builder
      | OpMod -> build_srem e1val e2val "modtemp" builder
      | OpEq -> build_icmp Icmp.Eq e1val e2val "ieqtemp" builder
      | OpNe -> build_icmp Icmp.Ne e1val e2val "inetemp" builder
      | OpLt -> build_icmp Icmp.Slt e1val e2val "ilttemp" builder
      | OpGt -> build_icmp Icmp.Sgt e1val e2val "igttemp" builder
      | OpLe -> build_icmp Icmp.Sle e1val e2val "iletemp" builder
      | OpGe -> build_icmp Icmp.Sge e1val e2val "igetemp" builder
      | OpBitAnd -> build_and e1val e2val "andtemp" builder
      | OpBitOr -> build_or e1val e2val "ortemp" builder
      | OpBitXor -> build_xor e1val e2val "xortemp" builder
      | _ -> failwith "int binop Not implemented yet"
    else if e1.decor = float_ttag then
      match op with
      | OpTimes -> build_fmul e1val e2val "fmultemp" builder
      | OpDiv -> build_fdiv e1val e2val "fdivtemp" builder
      | OpPlus -> build_fadd e1val e2val "faddtemp" builder
      | OpMinus -> build_fsub e1val e2val "fsubtemp" builder
      | _ -> failwith "float binop Not implemented yet"
    else if e1.decor = bool_ttag then
      match op with
      | OpAnd -> build_and e1val e2val "bandtemp" builder
      | OpOr -> build_or e1val e2val "bortemp" builder
      | OpEq -> build_icmp Icmp.Eq e1val e2val "beqtemp" builder
      | OpNe -> build_icmp Icmp.Ne e1val e2val "bnetemp" builder
      | _ -> failwith "BUG: type error in boolean binop"
    else
      failwith "unknown type for binary operation"
  )
  | ExpCall (fname, args) ->
     let (callee, llargs) = 
       gen_call the_module builder syms lltypes (fname, args) in
     build_call callee llargs "calltmp" builder

  | ExpNullAssn (_, _, _, _) ->
     failwith "BUG: null assign found outside condition"


(** Generate LLVM for a function call (used in both expr and stmt) *)
and gen_call the_module builder syms lltypes (fname, args) =
  let (fentry, _) = Symtable.findproc fname syms in
    match lookup_function fentry.procname the_module with
    (* lookup assumes procedure names are unique, which is how I intended *)
    | None -> failwith "BUG: unknown function name in codegen"
    | Some llfunc ->
       let llargs =
         List.map2 (fun (mut, argexpr) fparam ->
             (* mutable is pass-by-reference; get the variable expr's alloca *)
             if mut then
               match argexpr.e with
               | ExpVar _ -> (   (* (v, vlds) *)
                 let varentry, _ =
                   Symtable.findvar (exp_to_string argexpr) syms in
                 match varentry.addr with
                 | Some alloca ->
                    (* I think this is where I promote. *)
                    (* if varentry.symtype.nullable <> argexpr.decor.nullable then *)
                    if argexpr.decor.nullable then
                      failwith "Not yet supporting mutable nullable args"
                    else 
                      alloca
                 | None -> failwith "BUG: alloca not found for mutable arg"
               )
               | _ -> failwith "BUG: non-var mutable argument in codegen"
             else
               let argval = gen_expr the_module builder syms lltypes argexpr in
               (* Need to wrap value if passing into a union (nullable) type *)
               if argexpr.decor = fparam.symtype then
                 argval
               else
                 promote_value argval fparam.symtype builder lltypes
           ) args fentry.fparams
         |> Array.of_list in
       (llfunc, llargs) (* actual build is different if expr or stmt *)


let rec gen_stmt the_module builder lltypes (stmt: (typetag, 'a st_node) stmt) =
  let syms = stmt.decor in
  match stmt.st with
  | StmtDecl (varname, _, eopt) -> (
    (* technically, decl should only lookup in this scope. 
     * But we don't care in codegen, right, it's all correct? *)
    (* print_string ("looking up " ^ varname ^ " for decl codegen\n"); *)
    let (entry, _) = Symtable.findvar varname syms in
    let allocatype = ttag_to_llvmtype lltypes entry.symtype in
    (* Need to save the result? Don't think so, I'll grab it for stores. *)
    (* position_builder (instr_begin (insertion_block builder)) builder; *)
    let blockstart =
      (* TODO If in a function, will need to build it in entry block,
       * so it goes in the stack frame *)
      builder_at context (instr_begin (insertion_block builder)) in
    let alloca = build_alloca allocatype varname blockstart in 
    Symtable.set_addr syms varname alloca;
    match eopt with
    | None -> ()
    | Some initexp ->
       (* desugar to an assignment statement to avoid duplication. *)
       gen_stmt the_module builder lltypes
         {st=StmtAssign ((varname, []), initexp); decor=syms}
  )

  | StmtAssign ((varname, flds), ex) -> (
    (* let varname = String.concat "." (v::flds) in *)
    let (entry, _) = Symtable.findvar varname syms in
    match ex.e with
    (* For full-record assignment: desugar to individual assignments.
     * Could we just build a const_struct value instead? I think it has to
     * really be const *)
    | ExpRecord fieldlist ->
       let recaddr =
         let varaddr = gen_varexp_alloca entry flds lltypes builder in
         (* seemingly proper way: get the alloca to wherever the
            actual struct body is and do all the stores here. *)
         if entry.symtype.nullable then
           let tagaddr = build_struct_gep varaddr 0 "tagaddr" builder in
           ignore (build_store (const_int nulltag_type 1) tagaddr builder);
           build_struct_gep varaddr 1 "recaddr" builder
         else varaddr
       in 
       List.iter (fun (fname, fexp) ->
           (* have to use the map from fields to nums *)
           let fexpval = gen_expr the_module builder syms lltypes fexp in
           let fieldaddr =
             build_struct_gep recaddr
               (fst (Lltenv.find_field (entry.symtype.modulename,
                                        entry.symtype.typename)
                       fname lltypes)) "fieldaddr" builder in
           ignore (build_store fexpval fieldaddr builder)
         ) fieldlist
    (* normal single-value assignment: generate the expression. *)
    | _ -> (
      let expval = gen_expr the_module builder syms lltypes ex in
      let alloca =
        gen_varexp_alloca entry flds lltypes builder in
      print_endline (Llvm.string_of_llvalue alloca);
      (* handle string type specially (for now) *)
      (* cases to handle nullable types *)
      if entry.symtype.nullable = ex.decor.nullable then
        (* indirection level is the same, so just directly assign the value *)
        ignore (build_store expval alloca builder)
      else if ex.decor = null_ttag then (
        (* special case of null constant, just make a null tag *)
        print_endline "storing null value in nullable type";
        let nullval = const_int nulltag_type 0 in
        let tagaddr = build_struct_gep alloca 0 "tagaddr" builder in
        ignore (build_store nullval tagaddr builder))
      else if entry.symtype.nullable then (
        (* the expval is the value type; create the full record. *)
        let tagval = const_int nulltag_type 1 in
        let tagaddr = build_struct_gep alloca 0 "tagaddr" builder in
        ignore (build_store tagval tagaddr builder);
        let valaddr = build_struct_gep alloca 1 "valaddr" builder in
        ignore (build_store expval valaddr builder))
      else ( (* THINK THIS IS NOT USED HERE ANYMORE *)
        (* the expr is a struct? a pointer? gen_expr is never a pointer? *)
        (* let valaddr = build_struct_gep expval 1 "valaddr" builder in *)
        let realval = build_extractvalue expval 1 "realval" builder in
        (* build_load valaddr "realval" builder in *)
        ignore (build_store realval alloca builder))
  ))

  | StmtNop -> () (* will I need to generate so labels work? *)

  | StmtReturn eopt -> (
    (match eopt with
     | None -> ignore (build_ret_void builder)
     | Some rexp -> 
        let expval =
          let rettype =
            (Option.get stmt.decor.in_proc).rettype in
          let ev = gen_expr the_module builder syms lltypes rexp in
          if rexp.decor = rettype then ev
          (* need to wrap the value if it's a subtype. *)
          else (
            print_endline ("Calling promote_value for "
                           ^ Llvm.string_of_llvalue ev);
            promote_value ev rettype builder lltypes )
        in
        print_endline("got up to build_ret");
        ignore (build_ret expval builder)
    );
    (* Add a basic block after in case a break is added afterwards. *)
    let this_function =
      Option.get (lookup_function
                    (Option.get syms.in_proc).procname the_module) in
    let retcont_bb = append_block context "retcont" this_function in
    position_at_end retcont_bb builder;
  )

  | StmtIf (cond, thenblock, elsifs, elsopt) -> (
    (* Evaluate a condition, possibly inserting declaration and value store 
     * in the then block for conditional-null assignments. *)
    (* TODO: factor this out to use in while loops too *)
    let gen_cond cond thenbb thensyms =
      match cond.e with
      | ExpNullAssn (isdecl, (varname, flds), _, nullexp) ->
         let condval = gen_expr the_module builder syms lltypes nullexp in
         let nulltag = build_extractvalue condval 0 "nulltag" builder in
         (* Need an icmp instruction because tag value isn't i1 anymore. *)
         let condres =
           build_icmp Icmp.Ne
             nulltag (const_int nulltag_type 0) "condres" builder in
         (* construct a new declaration if needed, then generate code
          * to store the non-null condition result value *)
         position_at_end thenbb builder;
         if isdecl then
           gen_stmt the_module builder lltypes 
             { st=StmtDecl (varname, None, None); decor=thensyms };
         let (entry, _) = Symtable.findvar varname thensyms in
         let alloca =
           gen_varexp_alloca entry flds lltypes builder in
         let realval = build_extractvalue condval 1 "condval" builder in
         (* build_load valaddr "realval" builder in *)
         ignore (build_store realval alloca builder);
         condres
      | _ ->
         let condval = gen_expr the_module builder syms lltypes cond in
         (* need to handle nullable case here too *)
         if cond.decor.nullable then
           let nulltag = build_extractvalue condval 0 "nulltag" builder in
           build_icmp Icmp.Ne
             nulltag (const_int nulltag_type 0) "condres" builder
         else condval
    in
    let start_bb = insertion_block builder in
    let the_function = block_parent start_bb in
    let then_bb = append_block context "then" the_function in
    let thensyms = (List.hd thenblock).decor in
    let condval = gen_cond cond then_bb thensyms in
    position_at_end then_bb builder;
    List.iter (gen_stmt the_module builder lltypes) thenblock;
    let new_then_bb = insertion_block builder in
    (* elsif generating code *)
    let gen_elsif (cond, (block: (typetag, 'b) stmt list)) =
        (* however, need to insert conditional jump and jump-to-merge later *)
        let cond_bb = append_block context "elsifcond" the_function in
        position_at_end cond_bb builder;
        let then_bb = append_block context "elsifthen" the_function in
        let thensyms = (List.hd block).decor in
        let condval = gen_cond cond then_bb thensyms in
        position_at_end then_bb builder;
        List.iter (gen_stmt the_module builder lltypes) block;
        (condval, cond_bb, then_bb, insertion_block builder) (* for jumps *)
      in
      let elsif_blocks = List.map gen_elsif elsifs in
      (* generating dummy else block regardless. *)
      let else_bb = append_block context "else" the_function in
      position_at_end else_bb builder;
      (match elsopt with
       | Some elseblock ->
          List.iter (gen_stmt the_module builder lltypes) elseblock
       | None -> ());
      let new_else_bb = insertion_block builder in
      let merge_bb = append_block context "ifcont" the_function in
      (* kaleidoscope inserts the phi here *)
      (* position_at_end merge_bb builder; *)
      position_at_end start_bb builder;
      (* Still loop to the /original/ then block! *)
      let firstelse =
        match elsif_blocks with
        | [] -> else_bb
        | (_, condblk, _, _) :: _ -> condblk in
      (* This is where we build the first conditional! *)
      ignore (build_cond_br condval then_bb firstelse builder);
      position_at_end new_then_bb builder;
      ignore (build_br merge_bb builder);
      (* add conditional and unconditional jumps between elsif blocks *)
      let rec add_elsif_jumps = function
        | [] -> ()
        | (condval, condblk, thenblk, endblk) :: rest ->
           position_at_end condblk builder;
           (match rest with
            | [] ->
               ignore (build_cond_br condval thenblk else_bb builder);
            | (_, nextblk, _, _) :: _ -> 
               ignore (build_cond_br condval thenblk nextblk builder);
           );
           position_at_end endblk builder;
           ignore (build_br merge_bb builder);
           add_elsif_jumps rest
      in
      add_elsif_jumps elsif_blocks;
      position_at_end new_else_bb builder;
      ignore (build_br merge_bb builder);
      position_at_end merge_bb builder
  )

  | StmtWhile (cond, body) -> (
    (* test block, loop block, afterloop block. *)
    let the_function = block_parent (insertion_block builder) in 
    let test_bb = append_block context "test" the_function in
    (* jump from current block into this one *)
    ignore (build_br test_bb builder);
    (* insert code in test block to compute condition (put test in later) *)
    position_at_end test_bb builder;
    let condval = match cond.e with
      | ExpNullAssn (_,_,_,_) -> failwith "null assign not yet implemented"
      | _ -> gen_expr the_module builder syms lltypes cond in
    (* Create loop block and fill it in *)
    let loop_bb = append_block context "loop" the_function in
    position_at_end loop_bb builder;
    List.iter (gen_stmt the_module builder lltypes) body;
    (* add unconditional jump back to test *)
    let new_loop_bb = insertion_block builder in (* don't need? *)
    position_at_end new_loop_bb builder;         (* is it there already? *)
    ignore (build_br test_bb builder);
    let merge_bb = append_block context "afterloop" the_function in
    (* Now, add the conditional branch in the test block. *)
    position_at_end test_bb builder;
    ignore (build_cond_br condval loop_bb merge_bb builder);
    position_at_end merge_bb builder    
  )
  | StmtCall {decor=_; e=ExpCall (fname, args)} ->
     let (callee, llargs) = 
       gen_call the_module builder syms lltypes (fname, args) in
     ignore (build_call callee llargs "" builder)
  | StmtCall _ -> failwith "BUG: StmtCall without CallExpr"
  | StmtBlock _ -> failwith "not implemented"


(** Get a default value for a type. Seems to be needed for unreachable 
  * returns and empty union (nullable) fields. *)
let default_value ttag =
  (* I'll need some kind of ttag->llvm type mapping eventually. *)
  if ttag = int_ttag then const_int int_type 0
  else if ttag = float_ttag then const_float float_type 0.0
  else if ttag = bool_ttag then const_int bool_type 0
  else const_int int_type 0 (* Could we use this for all? *)
  (* else failwith ("Cannot generate default value for type "
                 ^ typetag_to_string ttag) *)


(** Generate value of a constant expression for a global var initializer. *)
let gen_constexpr_value (ex: typetag expr) =
  (* How many types will this support? Might need a tenv later *)
  if ex.decor = int_ttag then
    match ex.e with
    | ExpConst (IntVal n) -> const_int int_type n
    | _ -> failwith "Unsupported constant initializer, please add it"
  else if ex.decor = float_ttag then
    match ex.e with
    | ExpConst (FloatVal x) -> const_float float_type x
    | _ -> failwith "Unsupported constant initializer, please add it"
  else if ex.decor = bool_ttag then
    match ex.e with
    | ExpConst (BoolVal b) -> const_int bool_type (if b then 1 else 0)
    | _ -> failwith "Unsupported constant initializer, please add it"
  else failwith "Unknown constexpr type"   
    

(** Generate code for a global variable declaration (and constant initializer,
    for now) *)
let gen_global_decl the_module (gdecl: ('ed, 'sd) globalstmt) =
  let syms = gdecl.decor in
  match gdecl.init with
  | Some ex ->
     let gaddr =
       define_global gdecl.varname (gen_constexpr_value ex) the_module in
     Symtable.set_addr syms gdecl.varname gaddr;
  | None -> failwith "Shouldn't happen, global checked for initializer"


(** Generate llvm function decls for a set of proc symtable entries. *)
(* Used for both locals and imported functions. *)
let gen_fdecls the_module lltypes fsyms =
  StrMap.iter (fun _ procentry ->  (* don't need map keys *)
      let rettype = ttag_to_llvmtype lltypes procentry.rettype in
      let paramtypes =
        List.map (fun entry ->
            let ptype = ttag_to_llvmtype lltypes entry.symtype in
            (* make it the pointer type if it's passed mutable *)
            if entry.mut then
              if entry.symtype.nullable then
                (* If nullable we want a nullable pointer to the inner type. *)
                struct_type context [|
                    nulltag_type;
                    pointer_type (Lltenv.find_class_lltype
                                    entry.symtype.tclass lltypes)
                  |]
              else pointer_type ptype
            else ptype
          ) procentry.fparams
        |> Array.of_list in
      (* print_string ("Declaring function " ^ procentry.procname ^ "\n"); *)
      (* This is the qualified version (or not, if exported) *)
      let llfunc = (declare_function procentry.procname
                      (function_type rettype paramtypes) the_module) in
      print_endline (string_of_llvalue llfunc)
    (* We could set names for arguments here. *)
    ) fsyms  (* returns () *)


(** generate code for a procedure body (its declaration should already
 * be defined) *)
let gen_proc the_module builder lltypes proc =
  let fname = proc.decl.name in
  (* procedure is now defined in its own scope, so "getproc" *)
  let fentry = Symtable.getproc fname proc.decor in 
  match lookup_function fentry.procname the_module with
  | None -> failwith "BUG: llvm function lookup failed"
  | Some llfunc -> 
     (* should I define_function here, not add to the existing decl? *)
     let entry_bb = append_block context "entry" llfunc in
     position_at_end entry_bb builder;
     (* Set address of all arguments in symbol table, creating a new 
      * alloca for things passed by value *)
     List.iteri (fun i (_, varname, _) ->
         let entrybuilder =
           builder_at context (instr_begin (entry_block llfunc)) in
         let is_pointer_arg =
           classify_type (type_of (param llfunc i)) = TypeKind.Pointer in
         let alloca =
           (* trying to lower this to just "is pointer" *)
           if is_pointer_arg then param llfunc i
           else (build_alloca (type_of (param llfunc i)) varname entrybuilder)
         in
         if not is_pointer_arg then 
           ignore (build_store (param llfunc i) alloca builder);
         Symtable.set_addr proc.decor varname alloca
       ) proc.decl.params;
     List.iter (gen_stmt the_module builder lltypes) (proc.body);
     (* If procecure doesn't end in a terminator, add a void or dummy return *)
     if Option.is_none (block_terminator (insertion_block builder)) then
       (* Checking the LLVM type didn't work, why? *)
       (* if return_type (type_of llfunc) = void_type then ( *)
       if fentry.rettype = void_ttag then ( 
         ignore (build_ret_void builder);
         Llvm_analysis.assert_valid_function llfunc
       )
       else (
         (* dummy return, for unreachable code such as after ifs where all
          * branches return *)
         ignore (build_ret
                   (* at the LLVM level doesn't work here either. Why? *)
                   (* (const_null (return_type (type_of llfunc))) *)
                   (const_null (ttag_to_llvmtype lltypes fentry.rettype))
                   builder);
           (* ignore (build_ret (default_value fentry.rettype) builder); *)
         Llvm_analysis.assert_valid_function llfunc
       )


(** Generate LLVM code for an analyzed module. *)
let gen_module tenv topsyms layout (modtree: (typetag, 'a st_node) dillmodule) =
  let the_module = create_module context (modtree.name ^ ".ll") in
  (* Llvm.set_target_triple ttriple the_module; *)
  Llvm.set_data_layout (Llvm_target.DataLayout.as_string layout) the_module;
  let builder = builder context in
  (* Generate dict of llvm types for the type definitions. TODO: imports) *)
  let lltypes =
    TypeMap.fold (fun _ cdata lltenv ->
        (* fully-qualified typename now *)
        let newkey = (cdata.in_module, cdata.classname) in
        (* note that lltydata is a pair type. *)
        let lltydata = gen_lltype context tenv lltenv layout cdata in
        print_string (
            "adding type " ^ (fst newkey) ^ "::" ^ (snd newkey)
            ^ " to lltenv. "
            ^ (if type_is_sized (fst lltydata) then
                 "Size = " ^ string_of_llvalue (size_of (fst lltydata))
               else "Not sized.")
            ^ "\n"); 
        Lltenv.add newkey lltydata lltenv
      ) tenv Lltenv.empty in
  (* Generate decls for imports (already in the top symbol table node.) *)
  gen_fdecls the_module lltypes topsyms.fsyms;
  (* The next symtable node underneath has this module's proc declarations *)
  (* if List.length (topsyms.children) <> 1 then
    failwith "BUG: didn't find unique module-level symtable"; *)
  let modsyms = List.hd (topsyms.children) in
  List.iter (gen_global_decl the_module) modtree.globals;
  (* Generate proc declarations first, so they can mutually refer *)
  gen_fdecls the_module lltypes modsyms.fsyms;
  List.iter (gen_proc the_module builder lltypes) modtree.procs;
  Llvm_analysis.assert_valid_module the_module;
  the_module
