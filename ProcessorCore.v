(*
  This module integrates the processor components defined in FU.v
  into a single pipeline processor model.
*)

Require Import Kami.All FU CompressedInsts.
Require Import FpuKami.Definitions.
Require Import FpuKami.Classify.
Require Import FpuKami.Compare.
Require Import Vector.
Import VectorNotations.
Require Import List.
Import ListNotations.

Section Params.
  Variable name: string.
  Local Notation "^ x" := (name ++ "_" ++ x)%string (at level 0).

  Variable lgMemSz: nat.
  Variable Xlen_over_8: nat.
  Variable Flen_over_8: nat.
  Variable Rlen_over_8: nat.
  Local Notation Rlen := (Rlen_over_8 * 8).
  Local Notation Xlen := (Xlen_over_8 * 8).
  Local Notation Flen := (Flen_over_8 * 8).
  Local Notation Data := (Bit Rlen).
  Local Notation VAddr := (Bit Xlen).
  Local Notation FUEntry := (FUEntry Xlen_over_8 Rlen_over_8).
  Local Notation FetchPkt := (FetchPkt Xlen_over_8).
  Local Notation PktWithException := (PktWithException Xlen_over_8).

  Section model.
    Local Open Scope kami_action.
    Local Open Scope kami_expr.

    Variable func_units : forall ty, list (FUEntry ty).
    (* Variable mode       : forall ty, PrivMode @# ty. *)
    Variable supportedExts : ConstT (Extensions).

    Section Display.
      Variable ty : Kind -> Type.

      Local Definition expWidthMinus2
        :  nat
        := if Nat.eqb Flen_over_8 8
             then 9
             else 6.

      Local Definition sigWidthMinus2
        :  nat
        := if Nat.eqb Flen_over_8 8
             then 51
             else 22.

      Local Notation len := ((expWidthMinus2 + 1 + 1) + (sigWidthMinus2 + 1 + 1))%nat.

      Local Definition bitToFN (x : Bit len @# ty)
        :  FN expWidthMinus2 sigWidthMinus2 @# ty
        := unpack (FN expWidthMinus2 sigWidthMinus2) (ZeroExtendTruncLsb (size (FN expWidthMinus2 sigWidthMinus2)) x).

      Local Definition bitToNF (x : Bit len @# ty)
        :  NF expWidthMinus2 sigWidthMinus2 @# ty
        := getNF_from_FN (bitToFN x).

      Definition DispNF (prefix : string) (xlen : nat) (x : Bit xlen @# ty)
        := let y
             :  NF expWidthMinus2 sigWidthMinus2 @# ty
             := bitToNF (ZeroExtendTruncLsb len x) in
           [
             DispString _ prefix;
             DispBinary y;
             DispString _ "\n"
           ].

    End Display.

    Local Open Scope list.
    Definition processorCore 
      :  BaseModule
      := 
         MODULE {
              Register ^"pc"         : VAddr       <- ConstBit (_ 'h "00000000") with
              Register ^"fflags"     : FflagsValue <- ConstBit (natToWord FflagsWidth 0) with
              Register ^"frm"        : FrmValue    <- ConstBit (natToWord FrmWidth    0) with
              Register ^"mxl"
                :  MxlValue
(* TODO TESTING Dynamic Xlen *)
(*
                <- ConstBit (natToWord MxlWidth 1) with
*)
                <- ConstBit
                     (natToWord MxlWidth
                        (if Nat.eqb Xlen_over_8 4
                           then 1
                           else 2)) with
              Register ^"mode"             : PrivMode <- ConstBit (natToWord 2 MachineMode) with
              Register ^"extensions"       : Extensions  <- supportedExts with
              Register ^"mpp"              : Bit 2 <- ConstBit (natToWord 2 0) with
              Register ^"mpie"             : Bit 1 <- ConstBit (natToWord 1 0) with
              Register ^"mie"              : Bit 1 <- ConstBit (natToWord 1 0) with
              Register ^"mtvec_mode"       : Bit 2 <- ConstBit (natToWord 2 0) with
              Register ^"mtvec_base"       : Bit (Xlen - 2)%nat <- ConstBit (natToWord (Xlen - 2)%nat 0) with
              Register ^"mscratch"         : Bit Xlen <- ConstBit (natToWord Xlen 0) with
              Register ^"mepc"             : Bit Xlen <- ConstBit (natToWord Xlen 0) with
              Register ^"mcause_interrupt" : Bit 1 <- ConstBit (natToWord 1 0) with
              Register ^"mcause_code"      : Bit (Xlen - 1) <- ConstBit (natToWord (Xlen - 1) 0) with
              Register ^"mtval"            : Bit Xlen <- ConstBit (natToWord Xlen 0) with
              Rule ^"pipeline"
                := Read mxl : MxlValue <- ^"mxl";
                   Read mode : PrivMode <- ^"mode";
                   Read init_extensions
                     :  Extensions
                     <- ^"extensions";
                   LET extensions
                     :  Extensions
                     <- IF #mxl == $1
                          then
                            #init_extensions
                              @%["RV32I" <- $$true]
                              @%["RV64I" <- $$false]
                          else
                            #init_extensions
                              @%["RV32I" <- $$false]
                              @%["RV64I" <- $$true];
                   Write ^"extensions"
                     :  Extensions
                     <- #extensions;
                   System
                     [
                       DispString _ "Start\n";
                       DispString _ "XLEN_over_8: ";
                       DispDecimal (Const _ (natToWord 32 Xlen_over_8));
                       DispString _ "\n";
                       DispString _ "RLEN_over_8: ";
                       DispDecimal (Const _ (natToWord 32 Rlen_over_8));
                       DispString _ "\n";
                       DispString _ "MXL:\n";
                       DispDecimal #mxl;
                       DispString _ "Extensions:\n";
                       DispBinary #extensions
                     ];
                   Read pc : VAddr <- ^"pc";
                   System
                     [
                       DispString _ "Fetch\n";
                       DispString _ "  Fetched: ";
                       DispHex #pc;
                       DispString _ "\n"
                     ];
                   LETA fetch_pkt
                     :  PktWithException FetchPkt
                     <- fetch name lgMemSz Xlen_over_8 Rlen_over_8 #mxl (#pc);
                   System
                     [
                       DispString _ "Fetched\n";
                       DispString _ "  Inst: ";
                       DispHex #fetch_pkt;
                       DispString _ "\n        ";
                       DispBinary #fetch_pkt;
                       DispString _ "\n"
                     ];
                   System [DispString _ "Decoder\n"];
                   LETA decoder_pkt
                     <- convertLetExprSyntax_ActionT
                          (decoderWithException (func_units _) (CompInstDb _) #mxl #extensions #mode
                            (RetE (#fetch_pkt)));
                   System
                     [
                       DispString _ "Decode Pkt\n";
                       DispDecimal #decoder_pkt;
                       DispString _ "\n"
                     ];
                   System [DispString _ "Reg Read\n"];
                   LETA exec_context_pkt
                     <- readerWithException name Flen_over_8
                          (ITE
                            (#fetch_pkt @% "snd" @% "valid")
                            ((#fetch_pkt @% "snd" @% "data" @% "exception") == $InstAddrMisaligned)
                            $$(false))
                          (* TODO: does fetch raise this exception? *)
                          (ITE
                            (#fetch_pkt @% "snd" @% "valid")
                            ((#fetch_pkt @% "snd" @% "data" @% "exception") == $LoadAddrMisaligned)
                            $$(false))
                          (ITE
                            (#fetch_pkt @% "snd" @% "valid")
                            ((#fetch_pkt @% "snd" @% "data" @% "exception") == $InstAccessFault)
                            $$(false))
                          #mxl
                          #decoder_pkt;
                   System
                     ([
                       DispString _ "Reg Vals\n";
                       DispHex #exec_context_pkt;    
                       DispString _ "\n"
                     ] ++
                     (DispNF "    floating point value: " (#exec_context_pkt @% "fst" @% "reg1")) ++
                     (DispNF "    floating point value: " (#exec_context_pkt @% "fst" @% "reg2")) ++
                     (DispNF "    floating point value: " (#exec_context_pkt @% "fst" @% "reg3"))
                     );
                   System [DispString _ "Trans\n"];
                   LETA trans_pkt
                     <- convertLetExprSyntax_ActionT
                          (transWithException
                            (#mxl)
                            (#decoder_pkt @% "fst")
                            (#exec_context_pkt));
                   System [DispString _ "Executor\n"];
                   LETA exec_update_pkt
                     <- convertLetExprSyntax_ActionT
                          (execWithException (#trans_pkt));
                   System
                     ([
                       DispString _ "New Reg Vals\n";
                       DispHex #exec_update_pkt;    
                       DispString _ "\n"
                     ] ++
                     (DispNF "    floating point value: " (#exec_update_pkt @% "fst" @% "val1" @% "data" @% "data")) ++
                     (DispNF "    floating point value: " (#exec_update_pkt @% "fst" @% "val2" @% "data" @% "data")));
                   (* TODO: Add CSR Read operation here. CSR reads have side effects that register file reads do not. The spec requires that CSR reads not occur if the destination register is X0. *)
                   System [DispString _ "Mem\n"];
                   LETA mem_update_pkt
                     <- MemUnit name lgMemSz
                          ["mem"; "amo32"; "amo64"; "lrsc32"; "lrsc64"]
                          (#mxl)
                          (#decoder_pkt @% "fst")
                          (#exec_context_pkt @% "fst")
                          (#exec_update_pkt);
                   System
                     ([
                       DispString _ "New Reg Vals (after memory ops)\n";
                       DispHex #mem_update_pkt;    
                       DispString _ "\n"
                     ] ++
                     (DispNF "    floating point value: " (#mem_update_pkt @% "fst" @% "val1" @% "data" @% "data")) ++
                     (DispNF "    floating point value: " (#mem_update_pkt @% "fst" @% "val2" @% "data" @% "data")));
                   (* TODO: the call to commit currently ignores any exceptions propogated through mem_update_pkt. *)
                   System [DispString _ "Reg Write\n"];
                   LETA commit_pkt
                     :  Void
                     <- commit
                          name
                          Flen_over_8
                          #mxl
                          #pc
                          (#decoder_pkt @% "fst" @% "inst")
                          (#decoder_pkt @% "fst" @% "compressed?")
                          (#exec_context_pkt @% "fst")
                          #mem_update_pkt;
                   System [DispString _ "Inc PC\n"];
                   Call ^"pc"(#pc: VAddr); (* for test verification *)
                   Retv
         }.

    Definition intRegFile
      :  RegFileBase
      := @Build_RegFileBase
           false
           1
           (^"int_data_reg")
           (Async [(^"read_reg_1"); (^"read_reg_2")])
           (^"regWrite")
           32
           (Bit Xlen)
           (RFNonFile _ None).

    Definition floatRegFile
      :  RegFileBase
      := @Build_RegFileBase 
           false
           1
           (^"float_reg_file")
           (Async [(^"read_freg_1"); (^"read_freg_2"); (^"read_freg_3")])
           (^"fregWrite")
           32
           (Bit Flen)
           (RFNonFile _ None).
    
    Definition memRegFile
      :  RegFileBase
      := @Build_RegFileBase
           true
           Rlen_over_8
           (^"mem_reg_file")
           (Async [^"readMem1"; ^"readMem2"])
           (^"writeMem")
           (pow2 20)
           (Bit 8)
           (RFFile true true "testfile" (fun _ => wzero _)).

    Definition memReservationRegFile
      :  RegFileBase
      := @Build_RegFileBase
           true
           Rlen_over_8
           (^"memReservation_reg_file")
           (Async [^"readMemReservation"])
           (^"writeMemReservation")
           (pow2 20)
           Bool
           (RFNonFile _ (Some (ConstBool false))).

    Definition processor
      :  Mod 
      := createHideMod
           (fold_right
             ConcatMod
             processorCore
             (map
               (fun m => Base (BaseRegFile m)) 
               [   
                 intRegFile; 
                 floatRegFile; 
                 memRegFile;
                 memReservationRegFile
               ])) 
           [   
             ^"read_reg_1"; 
             ^"read_reg_2"; 
             ^"regWrite"; 
             ^"read_freg_1"; 
             ^"read_freg_2"; 
             ^"read_freg_3"; 
             ^"fregWrite";
             ^"readMem1";
             ^"readMem2";
             ^"readMemReservation";
             ^"writeMem";
             ^"writeMemReservation"
           ].  

    Definition model
      := getRtlSafe processor.

    Local Close Scope list.

    Local Close Scope kami_expr.
    Local Close Scope kami_action.

  End model.
End Params.
