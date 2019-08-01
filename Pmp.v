(*
  This module implements the physical memory protection interface.
*)
Require Import Kami.All.
Require Import Utila.
Require Import FU.
Require Import Vector.
Import VectorNotations.
Require Import List.
Import ListNotations.

Section pmp.

  Variable name: string.
  Variable Xlen_over_8: nat.
  Variable mem_params : MemParamsType.
  Variable ty : Kind -> Type.

  Local Notation "^ x" := (name ++ "_" ++ x)%string (at level 0).
  Local Notation Xlen := (Xlen_over_8 * 8).
  Local Notation PAddrSz := (Xlen).
  Local Notation granularity := (mem_params_granularity mem_params).
  Local Notation PAddr := (Bit PAddrSz).

  Open Scope kami_expr.
  Open Scope kami_action.

  Definition pmp_cfg_locked
    (pmp_cfg : Bit 8 @# ty)
    :  Bool @# ty
    := pmp_cfg$[7:7] == $1.

  Definition pmp_cfg_addr_mode
    (pmp_cfg : Bit 8 @# ty)
    :  Bit 2 @# ty
    := unsafeTruncLsb 2 (pmp_cfg >> Const ty (natToWord 2 3)).

  Definition pmp_cfg_execute
    (pmp_cfg : Bit 8 @# ty)
    :  Bool @# ty
    := pmp_cfg$[2:2] == $1.
    
  Definition pmp_cfg_write
    (pmp_cfg : Bit 8 @# ty)
    :  Bool @# ty
    := pmp_cfg$[1:1] == $1.
    
  Definition pmp_cfg_read
    (pmp_cfg : Bit 8 @# ty)
    :  Bool @# ty
    := unsafeTruncLsb 1 pmp_cfg == $1.

  Definition pmp_cfg_on
    (pmp_cfg : Bit 8 @# ty)
    :  Bool @# ty
    := pmp_cfg_addr_mode pmp_cfg != $0.

  Definition PmpEntryPkt
    := STRUCT_TYPE {
         "cfg" :: Bit 8;
         "addr" :: Bit 54
       }.

  Definition pmp_entry_read
    (n : nat)
    :  ActionT ty PmpEntryPkt
    := Read entry_cfg
         :  Bit 8
         <- ^("pmp" ++ nat_decimal_string n ++ "cfg");
       Read entry_addr
         :  Bit 54
         <- ^("pmpaddr" ++ nat_decimal_string n);
       Ret
         (STRUCT {
            "cfg" ::= #entry_cfg;
            "addr" ::= #entry_addr
          } : PmpEntryPkt @# ty).

  Local Definition PAddrExSz : nat := Xlen + 3.
  Local Definition PAddrEx := Bit PAddrExSz.

  Local Definition pmp_addr_acc_kind
    := STRUCT_TYPE {
         "any_matched" :: Bool;
         "all_matched" :: Bool
       }.

  Local Definition pmp_entry_acc_kind
    := STRUCT_TYPE {
         "any_on"  :: Bool;
         "addr"    :: PAddrEx;
         "matched" :: Bool;
         "pmp_cfg" :: Bit 8
       }.

  Definition pmp_check
    (f : Bit 8 @# ty -> Bool @# ty)
    (mode : PrivMode @# ty)
    (addr : PAddr @# ty)
    (addr_len : Bit 4 @# ty)
    :  ActionT ty Bool
    := (* System [
         DispString _ "[pmp_check] addr: ";
         DispBinary addr;
         DispString _ "\n";
         DispString _ "[pmp_check] addr len: ";
         DispHex addr_len;
         DispString _ "\n"
       ]; *)
       LETA result
         :  pmp_entry_acc_kind
         <- fold_right
              (fun entry_index (acc_act : ActionT ty pmp_entry_acc_kind)
                => LETA acc <- acc_act;
                   (* System [
                     DispString _ "[pmp_check] ==================================================\n";
                     DispString _ "[pmp_check] acc: ";
                     DispHex #acc;
                     DispString _ "\n"
                   ]; *)
                   If #acc @% "matched" 
                     then Ret #acc
                     else
                       LETA entry
                         :  PmpEntryPkt
                         <- pmp_entry_read entry_index;
                       LET tor
                         :  PAddrEx
                         <- (SignExtendTruncLsb PAddrExSz (#entry @% "addr")) << (Const ty (natToWord 2 2)); 
                       (* System [
                         DispString _ "[pmp_check] entry: ";
                         DispHex #entry;
                         DispString _ "\n";
                         DispString _ "[pmp_check] entry addr: ";
                         DispBinary (#entry @% "addr");
                         DispString _ "\n";
                         DispString _ "[pmp_check] sign extended entry addr: ";
                         DispBinary (SignExtendTruncLsb PAddrExSz (ZeroExtendTruncLsb 54 (#entry @% "addr")));
                         DispString _ "\n";
                         DispString _ "[pmp_check] tor: ";
                         DispBinary #tor;
                         DispString _ "\n"
                       ]; *)
                       If pmp_cfg_addr_mode (#entry @% "cfg") == $0
                         then
                           Ret (STRUCT {
                             "any_on"  ::= #acc @% "any_on";
                             "addr"    ::= #tor;
                             "matched" ::= $$false;
                             "pmp_cfg" ::= $0
                           } : pmp_entry_acc_kind @# ty)
                         else
                           LET mask0
                             :  PAddrEx
                             <- ((SignExtendTruncLsb PAddrExSz (#entry @% "addr")) << (Const ty (natToWord 1 1))) | $1;
                           LET mask
                             :  PAddrEx
                             <- ~ (#mask0 & (~ (#mask0 + $1))) << (Const ty (natToWord 2 2));
                           (* System [
                             DispString _ "[pmp_check] mask: ";
                             DispHex #mask;
                             DispString _ "\n"
                           ]; *)
                           LETA addr_result
                             :  pmp_addr_acc_kind
                             <- fold_right
                                  (fun index (addr_acc_act : ActionT ty pmp_addr_acc_kind)
                                    => LET offset
                                         :  Bit 4
                                         <- Const ty (natToWord 4 (4 * index)%nat);
                                       (* System [
                                         DispString _ "[pmp_check] --------------------------------------------------\n";
                                         DispString _ "[pmp_check] offset: ";
                                         DispHex #offset;
                                         DispString _ "\n"
                                       ]; *)
                                       If addr_len < #offset
                                         then
                                           (* System [
                                             DispString _ "[pmp_check] offset greater than region length.\n";
                                             DispString _ "[pmp_check] addr_len: ";
                                             DispBinary addr_len;
                                             DispString _ "\n";
                                             DispString _ "[pmp_check] offset: ";
                                             DispBinary #offset;
                                             DispString _ "\n"
                                           ]; *)
                                           addr_acc_act
                                         else 
                                           LETA addr_acc <- addr_acc_act;
                                           LET curr_addr
                                             :  PAddrEx
                                             <- SignExtendTruncLsb PAddrExSz
                                                  (addr + (ZeroExtendTruncLsb PAddrSz #offset));
                                           LET napot_match
                                             :  Bool
                                             <- ((CABit Bxor [#curr_addr; #tor]) & #mask) == $0;
                                           LET tor_match
                                             :  Bool
                                             <- (#acc @% "addr" <= #curr_addr) && (#curr_addr < #tor);
                                           LET matched
                                             :  Bool
                                             <- IF #entry @% "cfg" == $1
                                                  then #tor_match
                                                  else #napot_match;
                                           (* System [
                                             DispString _ "[pmp_check] addr acc: ";
                                             DispHex #addr_acc;
                                             DispString _ "\n";
                                             DispString _ "[pmp_check] curr addr: ";
                                             DispHex #curr_addr;
                                             DispString _ "\n";
                                             DispString _ "[pmp_check] napot reference: ";
                                             DispHex ((CABit Bxor [#curr_addr; #tor]) & #mask);
                                             DispString _ "\n";
                                             DispString _ "[pmp_check] napot match: ";
                                             DispHex #napot_match;
                                             DispString _ "\n";
                                             DispString _ "[pmp_check] tor match: ";
                                             DispHex #tor_match;
                                             DispString _ "\n";
                                             DispString _ "[pmp_check] matched: ";
                                             DispHex #matched;
                                             DispString _ "\n"
                                           ]; *)
                                           Ret (STRUCT {
                                             "any_matched" ::= ((#addr_acc @% "any_matched") || #matched);
                                             "all_matched" ::= ((#addr_acc @% "all_matched") && #matched)
                                           } : pmp_addr_acc_kind @# ty)
                                         as result;
                                       Ret #result)
                                  (Ret (STRUCT {
                                     "any_matched" ::= $$false;
                                     "all_matched" ::= $$true
                                   } : pmp_addr_acc_kind @# ty))
                                  (seq 0 2);
                           If #addr_result @% "any_matched"
                             then 
                               (* System [
                                 DispString _ "[pmp_check] addr any matched\n"
                               ]; *)
                               Ret (STRUCT {
                                 "any_on"  ::= $$true;
                                 "addr"    ::= $0;
                                 "matched" ::= #addr_result @% "all_matched";
                                 "pmp_cfg" ::= #entry @% "cfg" (* ((#addr_result @% "all_matched") && (f (#entry @% "cfg"))) *)
                               } : pmp_entry_acc_kind @# ty)
                             else 
                               (* System [
                                 DispString _ "[pmp_check] addr none matched\n"
                               ]; *)
                               Ret (STRUCT {
                                 "any_on"  ::= #acc @% "any_on";
                                 "addr"    ::= #acc @% "addr";
                                 "matched" ::= $$false;
                                 "pmp_cfg" ::= $0
                               } : pmp_entry_acc_kind @# ty)
                             as result;
                           Ret #result
                         as result;
                       Ret #result
                     as result;
                   Ret #result)
              (Ret (STRUCT {
                 "any_on"  ::= $$false;
                 "addr"    ::= $0;
                 "matched" ::= $$false;
                 "pmp_cfg" ::= $0
               } : pmp_entry_acc_kind @# ty))
              (seq 0 16);
       (* System [
         DispString _ "[pmp_check] ##################################################\n";
         DispString _ "[pmp_check] result: ";
         DispHex #result;
         DispString _ "\n"
       ]; *)
       Ret (* (#result @% "result").  *)
         (IF #result @% "matched"
           then
             (mode == $MachineMode && !pmp_cfg_locked (#result @% "pmp_cfg")) ||
             (f (#result @% "pmp_cfg"))
           else
             (mode == $MachineMode)).

  Definition pmp_check_execute 
    :  PrivMode @# ty -> PAddr @# ty -> Bit 4 @# ty -> ActionT ty Bool
    := pmp_check pmp_cfg_execute.
  
  Definition pmp_check_write
    :  PrivMode @# ty -> PAddr @# ty -> Bit 4 @# ty -> ActionT ty Bool
    := pmp_check pmp_cfg_write.

  Definition pmp_check_read
    :  PrivMode @# ty -> PAddr @# ty -> Bit 4 @# ty -> ActionT ty Bool
    := pmp_check pmp_cfg_read.

  Close Scope kami_action.
  Close Scope kami_expr.

End pmp.
