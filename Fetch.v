(*
  Contains definitions describing the interface to the fetch unit.
*)
Require Import Kami.All.
Import Syntax.
Require Import FU.

Section fetch.

Variable Xlen_over_8 : nat.

Variable ty : Kind -> Type.

Local Notation Xlen := (8 * Xlen_over_8).

Local Notation VAddr := (Bit Xlen).

Definition ExceptionInfo := Bit Xlen.

Definition FullException := STRUCT {
                                "exception" :: Exception ;
                                "value" :: ExceptionInfo }.

Definition PktWithException k := Pair k (Maybe FullException).

Definition FetchPkt := STRUCT {
                           "pc" :: VAddr ;
                           "inst" :: Inst }.

Definition FetchStruct := PktWithException FetchPkt.

Definition InstException := STRUCT {
                                "inst" :: Inst ;
                                "exception" :: Maybe FullException }.
  
Open Scope kami_expr.

Definition mkPktWithException k1 (pkt1: PktWithException k1 @# ty)
           k2 (pkt2: PktWithException k2 @# ty) :=
    IF (pkt1 @% "snd" @% "valid")
          then pkt2@%["snd" <- pkt1 @% "snd"]
          else pkt2.

Open Scope kami_action.

Definition fetch (pc: VAddr @# ty) : ActionT ty FetchStruct :=
  (Call instException : InstException <- "fetch"(pc: _);
     LET retVal: FetchStruct <- (STRUCT {
                                     "fst" ::=
                                       (STRUCT {
                                            "pc" ::= pc ;
                                            "inst" ::= #instException @% "inst" }:
                                          FetchPkt @# ty) ;
                                     "snd" ::= #instException @% "exception" });
     Ret #retVal).

Close Scope kami_action.
Close Scope kami_expr.

End fetch.