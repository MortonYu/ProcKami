(*
  This module defines the memory unit. This unit accepts a memory
  update packet and performs the requested memory writes.
*)
Require Import Kami.All.
Require Import FU.
Require Import Decoder.
Require Import Pmp.
Require Import PhysicalMem.
Require Import RiscvPipeline.MemUnit.PageTable.
Require Import List.
Import ListNotations.

Section mem_unit.

  Variable name: string.
  Variable Xlen_over_8: nat.
  Variable Rlen_over_8: nat.
  Variable mem_params : MemParamsType.
  Variable supported_exts : list (string * bool).
  Variable ty: Kind -> Type.

  Local Notation "^ x" := (name ++ "_" ++ x)%string (at level 0).
  Local Notation Rlen := (Rlen_over_8 * 8).
  Local Notation Xlen := (Xlen_over_8 * 8).
  Local Notation Data := (Bit Rlen).
  Local Notation VAddr := (Bit Xlen).
  Local Notation PAddrSz := (Xlen).
  Local Notation PAddr := (Bit PAddrSz).
  Local Notation InstEntry := (InstEntry Xlen_over_8 Rlen_over_8 ty).
  Local Notation FUEntry := (FUEntry Xlen_over_8 Rlen_over_8 supported_exts ty).
  Local Notation FetchPkt := (FetchPkt Xlen_over_8).
  Local Notation ExecContextPkt := (ExecContextPkt Xlen_over_8 Rlen_over_8).
  Local Notation ExecUpdPkt := (ExecUpdPkt Rlen_over_8).
  Local Notation RoutedReg := (RoutedReg Rlen_over_8). 
  Local Notation PktWithException := (PktWithException Xlen_over_8).
  Local Notation FullException := (FullException Xlen_over_8).
  Local Notation MemWrite := (MemWrite Rlen_over_8 PAddrSz).
  Local Notation MemoryInput := (MemoryInput Rlen_over_8).
  Local Notation MemoryOutput := (MemoryOutput Rlen_over_8).
  Local Notation MemUnitInput := (MemUnitInput Rlen_over_8).
  Local Notation MemRet := (MemRet Rlen_over_8).
  Local Notation XlenValue := (XlenValue Xlen_over_8).

  Local Notation pMemReadReservation := (@pMemReadReservation name Xlen_over_8 Rlen_over_8 mem_params ty).
  Local Notation pMemWriteReservation := (@pMemWriteReservation name Xlen_over_8 Rlen_over_8 mem_params ty).

  Variable func_units : list FUEntry.
  Local Notation FuncUnitId := (@Decoder.FuncUnitId Xlen_over_8 Rlen_over_8 supported_exts ty func_units).
  Local Notation InstId := (@Decoder.InstId Xlen_over_8 Rlen_over_8 supported_exts ty func_units).
  Local Notation DecoderPkt := (@Decoder.DecoderPkt Xlen_over_8 Rlen_over_8 supported_exts ty func_units).

  Local Notation MemDevice := (@MemDevice Rlen_over_8 PAddrSz).
  Variable mem_devices : list MemDevice.

  Local Notation MemTableEntry := (@MemTableEntry Rlen_over_8 PAddrSz mem_devices).
  Variable mem_table : list MemTableEntry.

  Local Definition DeviceTag := (@DeviceTag Rlen_over_8 PAddrSz mem_devices).
  Opaque DeviceTag.

  Local Notation checkForFault := (@checkForFault name Xlen_over_8 Rlen_over_8 mem_devices mem_table ty).
  Local Notation mem_region_read := (@mem_region_read Xlen_over_8 Rlen_over_8 mem_devices ty).
  Local Notation mem_region_write := (@mem_region_write Xlen_over_8 Rlen_over_8 mem_devices ty).

  Local Definition baseIndex := 3. (* the first available read port available to the page table walker. *)
  Local Notation pt_walker := (@pt_walker name Xlen_over_8 Rlen_over_8 ty mem_devices mem_table baseIndex).

  Local Notation lgSizeWidth := (lgSizeWidth Rlen_over_8).
  Local Notation LgSize := (LgSize Rlen_over_8).

  Open Scope kami_expr.
  Open Scope kami_action.

  (* TODO: should this be sign extended? *)
  Definition pMemTranslate
    (vaddr : VAddr @# ty)
    :  PktWithException PAddr @# ty
    := STRUCT {
         "fst" ::= ZeroExtendTruncLsb PAddrSz vaddr;
         "snd" ::= Invalid
       } : PktWithException PAddr @# ty.

  Definition memTranslate
    (index : nat) (* 0 based index specifying which call to the page table walker this is. *)
    (satp_mode : Bit SatpModeWidth @# ty)
    (mode : PrivMode @# ty)
    (access_type : VmAccessType @# ty)
    (vaddr : VAddr @# ty)
    :  ActionT ty (PktWithException PAddr)
    := Read mpp : PrivMode <- ^"mpp";
       Read mprv : Bool <- ^"mprv";
       Read mxr : Bool <- ^"mxr";
       Read sum : Bool <- ^"sum";
       Read satp_ppn : Bit 44 <- ^"satp_ppn";
       LET transMode
         :  Maybe PrivMode
         <- IF mode == $MachineMode
              then
                (* See 3.1.9 *)
                IF #mprv
                  then Valid #mpp
                  else Invalid
              else Valid mode;
       If #transMode @% "valid" && (!(satp_mode == $SatpModeBare))
         then
           LETA paddr : PktWithException PAddr
             <- pt_walker
                  index
                  satp_mode
                  #mxr
                  #sum
                  (#transMode @% "data")
                  (ppnToPAddr Xlen_over_8 (ZeroExtendTruncLsb 44 #satp_ppn))
                  access_type
                  vaddr;
           Ret #paddr
         else
           Ret (pMemTranslate vaddr)
         as result;
       Ret #result.

  Definition memFetch
    (index : nat)
    (satp_mode: Bit SatpModeWidth @# ty)
    (mode : PrivMode @# ty) 
    (vaddr : VAddr @# ty)
    :  ActionT ty (PktWithException Data)
    := LETA paddr
         :  PktWithException PAddr
         <- memTranslate index satp_mode mode $VmAccessInst vaddr;
       System [
         DispString _ "[memFetch] paddr: ";
         DispHex #paddr;
         DispString _ "\n"
       ];
       If #paddr @% "snd" @% "valid"
         then
           Ret
             (STRUCT {
                "fst" ::= $0;
                "snd" ::= #paddr @% "snd"
              } : PktWithException Data @# ty)
         else
           LETA pmp_result
             :  Pair (Pair DeviceTag PAddr) MemErrorPkt
             <- checkForFault $VmAccessInst satp_mode mode (#paddr @% "fst") $1 $$false;
           If mem_error (#pmp_result @% "snd")
             then
               LET exception
                 :  Maybe FullException
                 <- Valid (STRUCT {
                        "exception"
                          ::= IF #pmp_result @% "snd" @% "misaligned"
                                then $InstAddrMisaligned
                                else $InstAccessFault;
                        "value" ::= vaddr
                      } : FullException @# ty);
               Ret (STRUCT {
                   "fst" ::= $0;
                   "snd" ::= #exception
                 } : PktWithException Data @# ty)
             else
               LETA inst
                 :  Maybe Data
                 <- mem_region_read index mode
                      (#pmp_result @% "fst" @% "fst") 
                      (#pmp_result @% "fst" @% "snd")
                      $2;
               LET exception
                 :  FullException
                 <- STRUCT {
                      "exception" ::= $InstAccessFault;
                      "value"     ::= vaddr
                    } : FullException @# ty;
               Ret (STRUCT {
                   "fst" ::= #inst @% "data";
                   "snd"
                     ::= IF #inst @% "valid"
                           then Invalid
                           else Valid #exception
                 } : PktWithException Data @# ty)
             as result;
           Ret #result
         as result;
       Ret #result.

  Local Definition mem_unit_exec_pkt
    (memRet : MemRet @# ty)
    (exception : Maybe FullException @# ty)
    :  ActionT ty (PktWithException MemRet)
    := Ret
         (STRUCT {
            "fst" ::= memRet;
            "snd" ::= exception
          } : PktWithException MemRet @# ty).

  Local Definition mem_unit_exec_pkt_def
    (exception : Maybe FullException @# ty)
    :  ActionT ty (PktWithException MemRet)
    := mem_unit_exec_pkt
         $$(getDefaultConst MemRet)
         exception.

  Local Definition mem_unit_exec_pkt_access_fault
    (vaddr : VAddr @# ty)
    (is_write : Bool @# ty)
    :  ActionT ty (PktWithException MemRet)
    := mem_unit_exec_pkt_def
         (Valid (STRUCT {
           "exception"
             ::= (IF is_write
                   then $SAmoAccessFault
                   else $LoadAccessFault
                   : Exception @# ty);
           "value" ::= vaddr
         } : FullException @# ty)).

  Definition mem_unit_exec
    (satp_mode: Bit SatpModeWidth @# ty)
    (mode : PrivMode @# ty)
    (addr : VAddr @# ty)
    (func_unit_id : FuncUnitId @# ty)
    (inst_id : InstId @# ty)
    (input_pkt : MemUnitInput @# ty)
    :  ActionT ty (PktWithException MemRet)
    := (* I. does the instruction perform a memory operation? *)
       System [
         DispString _ "[mem_unit_exec] input pkt:\n";
         DispHex input_pkt;
         DispString _ "\n";
         DispString _ "[mem_unit_exec] functional unit ID:\n";
         DispHex func_unit_id;
         DispString _ "\n";
         DispString _ "[mem_unit_exec] inst ID:\n";
         DispHex inst_id;
         DispString _ "\n"
       ];
       LETA mis_op
         :  Maybe Bool
         <- convertLetExprSyntax_ActionT
              (inst_db_get_pkt
                (fun _ _ tagged_inst
                  => let inst := snd tagged_inst in
                     RetE
                       (match optMemParams inst with
                         | Some _ => $$true
                         | None => $$false
                         end))
                func_unit_id
                inst_id);
       If #mis_op @% "data"
         then
           (* II. does the instruction perform a memory write? *)
           LETA mis_write
             :  Maybe Bool
             <- convertLetExprSyntax_ActionT
                  (inst_db_get_pkt
                    (fun _ _ tagged_inst
                      => RetE (if writeMem (instHints (snd tagged_inst)) then $$true else $$false))
                    func_unit_id
                    inst_id);
           LETA msize
             :  Maybe LgSize
             <-  convertLetExprSyntax_ActionT
                   (inst_db_get_pkt
                     (fun _ _ tagged_inst
                       => RetE
                            (match optMemParams (snd tagged_inst) with
                              | Some params => $(accessSize params)
                              | _ => $0
                              end))
                     func_unit_id
                     inst_id);
           (* III. get the physical address *)
           LETA mpaddr
             :  PktWithException PAddr
             <- memTranslate 2 satp_mode mode
                  (IF #mis_write @% "data"
                    then $VmAccessSAmo
                    else $VmAccessLoad)
                  addr;
           If #mpaddr @% "snd" @% "valid"
             then
               System [
                 DispString _ "[mem_unit_exec] the page table walker threw an exception\n"
               ];
               Ret (STRUCT {
                   "fst" ::= $$(getDefaultConst MemRet);
                   "snd" ::= #mpaddr @% "snd"
                 } : PktWithException MemRet @# ty)
             else
               LETA pmp_result
                 :  Pair (Pair DeviceTag PAddr) MemErrorPkt
                 <- checkForFault
                      (IF #mis_write @% "data"
                        then $VmAccessSAmo
                        else $VmAccessLoad)
                      satp_mode
                      mode
                      (#mpaddr @% "fst")
                      (#msize @% "data")
                      (input_pkt @% "aq" || input_pkt @% "rl");
               If mem_error (#pmp_result @% "snd")
                 then (* TODO: return misaligned exception if mem error is misaligned. *)
                   System [
                     DispString _ "[mem_unit_exec] the pmp check failed\n"
                   ];
                   LET exception
                     :  Maybe FullException
                     <- Valid (STRUCT {
                          "exception"
                            ::= IF #pmp_result @% "snd" @% "misaligned"
                                  then
                                    (IF #mis_write @% "data"
                                      then $SAmoAddrMisaligned
                                      else $LoadAddrMisaligned)
                                  else
                                    (IF #mis_write @% "data"
                                      then $SAmoAccessFault
                                      else $LoadAccessFault);
                          "value" ::= ZeroExtendTruncLsb Xlen (#mpaddr @% "fst")
                        } : FullException @# ty);
                   mem_unit_exec_pkt_def #exception
                 else
                   (* IV. read the current value and place reservation *)
                   LETA read_result
                     :  Maybe Data
                     <- mem_region_read 2 mode
                          (#pmp_result @% "fst" @% "fst")
                          (#pmp_result @% "fst" @% "snd")
                          (#msize @% "data");
                   If #read_result @% "valid"
                     then
                       (* TODO: should we place reservations on failed reads? *)
                       LETA read_reservation_result
                         :  Array Rlen_over_8 Bool
                         <- pMemReadReservation (unsafeTruncLsb PAddrSz (#mpaddr @% "fst"));
                       (* VI. apply the memory transform to compute the write value *)
                       LETA mwrite_value
                         :  Maybe MemoryOutput
                         <- convertLetExprSyntax_ActionT
                              (inst_db_get_pkt
                                (fun _ _ tagged_inst
                                  => let inst := snd (tagged_inst) in
                                     match optMemParams inst return MemoryOutput ## ty with
                                       | Some params
                                         => (((memXform params)
                                              (RetE
                                                (STRUCT {
                                                  "aq" ::= input_pkt @% "aq" ;
                                                  "rl" ::= input_pkt @% "rl" ;
                                                  "reservation" ::= #read_reservation_result;
                                                  "mem" ::= #read_result @% "data";
                                                  "reg_data" ::= input_pkt @% "reg_data"
                                                 } : MemoryInput @# ty))) : MemoryOutput ## ty)
                                       | None (* impossible case *)
                                         => RetE $$(getDefaultConst MemoryOutput)
                                       end)
                                func_unit_id
                                inst_id);
                       If #mwrite_value @% "data" @% "isWr"
                         then
                           (* VII. write to memory. *)
                           LET write_mask
                             :  Array Rlen_over_8 Bool
                             <- #mwrite_value @% "data" @% "mask";
                           LETA write_result
                             :  Bool
                             <- mem_region_write 0 mode
                                  (#pmp_result @% "fst" @% "fst")
                                  (#pmp_result @% "fst" @% "snd")
                                  (#mwrite_value @% "data" @% "data" : Data @# ty)
                                  (#write_mask : Array Rlen_over_8 Bool @# ty)
                                  (#msize @% "data");
                           Ret
                             (IF #write_result
                               then
                                 Valid (STRUCT {
                                     "exception" ::= $SAmoAccessFault;
                                     "value" ::= addr
                                   } : FullException @# ty)
                               else Invalid)
                         else Ret Invalid
                         as write_result;
                       System [
                         DispString _ "[mem_unit_exec] write result:\n";
                         DispHex #write_result;
                         DispString _ "\n"
                       ];
                       If #mwrite_value @% "data" @% "isLrSc"
                         then pMemWriteReservation
                                (#mpaddr @% "fst")
                                (#mwrite_value @% "data" @% "mask")
                                (#mwrite_value @% "data" @% "reservation");
                       LET memRet
                         :  MemRet
                         <- STRUCT {
                              "writeReg?" ::= #mwrite_value @% "data" @% "reg_data" @% "valid";
                              "tag"  ::= #mwrite_value @% "data" @% "tag";
                              "data" ::= #mwrite_value @% "data" @% "reg_data" @% "data"
                            } : MemRet @# ty;
                       mem_unit_exec_pkt #memRet #write_result
                     else mem_unit_exec_pkt_access_fault addr $$false
                     as result;
                   Ret #result
                 as result;
               Ret #result
             as result;
           Ret #result
         else
           System [
             DispString _ "[mem_unit_exec] the instruction does not perform an memory operations.\n"
           ];
           (mem_unit_exec_pkt_def Invalid)
         as result;
         System [
           DispString _ "[mem_unit_exec] result:\n";
           DispHex #result;
           DispString _ "\n"
         ];
       Ret #result.

  Definition MemUnit
    (xlen : XlenValue @# ty)
    (satp_mode: Bit SatpModeWidth @# ty)
    (mode : PrivMode @# ty)
    (decoder_pkt : DecoderPkt @# ty)
    (exec_context_pkt : ExecContextPkt @# ty)
    (update_pkt : ExecUpdPkt @# ty)
    (exception : Maybe FullException @# ty)
    :  ActionT ty (PktWithException ExecUpdPkt)
    := bindException update_pkt exception
         (fun update_pkt : ExecUpdPkt @# ty
           => LET memUnitInput
                :  MemUnitInput
                <- STRUCT {
                     "aq"       ::= update_pkt @% "aq";
                     "rl"       ::= update_pkt @% "rl";
                     "reg_data" ::= exec_context_pkt @% "reg2"
                     } : MemUnitInput @# ty;
              LETA memRet
                :  PktWithException MemRet
                <- mem_unit_exec
                     satp_mode
                     mode
                     (xlen_sign_extend Xlen xlen
                       (update_pkt @% "val1" @% "data" @% "data" : Bit Rlen @# ty))
                     (decoder_pkt @% "funcUnitTag")
                     (decoder_pkt @% "instTag")
                     #memUnitInput;
              LET val1
                :  RoutedReg
                <- STRUCT {
                     "tag"  ::= #memRet @% "fst" @% "tag";
                     "data" ::= #memRet @% "fst" @% "data"
                   } : RoutedReg @# ty;
              LET mem_update_pkt
                :  ExecUpdPkt
                <- IF #memRet @% "fst" @% "writeReg?"
                     then update_pkt @%["val1" <- Valid #val1]
                     else update_pkt;
              Ret (STRUCT {
                  "fst" ::= #mem_update_pkt;
                  "snd" ::= #memRet @% "snd"
                } : PktWithException ExecUpdPkt @# ty)).

  Close Scope kami_expr.
  Close Scope kami_action.

End mem_unit.