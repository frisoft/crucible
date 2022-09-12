# -*- coding: utf-8 -*-
# Generated by the protocol buffer compiler.  DO NOT EDIT!
# source: crucible_protobuf_trace/operation_trace.proto
"""Generated protocol buffer code."""
from google.protobuf.internal import builder as _builder
from google.protobuf import descriptor as _descriptor
from google.protobuf import descriptor_pool as _descriptor_pool
from google.protobuf import symbol_database as _symbol_database
# @@protoc_insertion_point(imports)

_sym_db = _symbol_database.Default()


from crucible_protobuf_trace import common_pb2 as crucible__protobuf__trace_dot_common__pb2
from crucible_protobuf_trace import sym_expr_pb2 as crucible__protobuf__trace_dot_sym__expr__pb2
from crucible_protobuf_trace import memory_events_pb2 as crucible__protobuf__trace_dot_memory__events__pb2
from crucible_protobuf_trace import assumptions_pb2 as crucible__protobuf__trace_dot_assumptions__pb2
from crucible_protobuf_trace import abort_pb2 as crucible__protobuf__trace_dot_abort__pb2


DESCRIPTOR = _descriptor_pool.Default().AddSerializedFile(b'\n-crucible_protobuf_trace/operation_trace.proto\x1a$crucible_protobuf_trace/common.proto\x1a&crucible_protobuf_trace/sym_expr.proto\x1a+crucible_protobuf_trace/memory_events.proto\x1a)crucible_protobuf_trace/assumptions.proto\x1a#crucible_protobuf_trace/abort.proto\">\n\tAssertion\x12 \n\tpredicate\x18\x01 \x01(\x0b\x32\r.ExpressionID\x12\x0f\n\x07message\x18\x02 \x01(\t\"\x16\n\x06PathID\x12\x0c\n\x04text\x18\x01 \x01(\t\"X\n\tPathSplit\x12&\n\x0fsplit_condition\x18\x01 \x01(\x0b\x32\r.ExpressionID\x12#\n\x12\x63ontinuing_path_id\x18\x02 \x01(\x0b\x32\x07.PathID\"\xdf\x01\n\tPathMerge\x12 \n\x0fmerging_path_id\x18\x01 \x01(\x0b\x32\x07.PathID\x12+\n\x0fmerge_condition\x18\x02 \x01(\x0b\x32\r.ExpressionIDH\x00\x88\x01\x01\x12&\n\x10path_assumptions\x18\x03 \x01(\x0b\x32\x0c.Assumptions\x12\'\n\x11other_assumptions\x18\x04 \x01(\x0b\x32\x0c.Assumptions\x12\x1e\n\rpath_id_after\x18\x05 \x01(\x0b\x32\x07.PathIDB\x12\n\x10_merge_condition\"\xcb\x01\n\x0c\x42ranchSwitch\x12\x1d\n\x0cid_suspended\x18\x01 \x01(\x0b\x32\x07.PathID\x12\x1b\n\nid_resumed\x18\x02 \x01(\x0b\x32\x07.PathID\x12\'\n\x10\x62ranch_condition\x18\x03 \x01(\x0b\x32\r.ExpressionID\x12)\n\x0f\x62ranch_location\x18\x04 \x01(\x0b\x32\x10.MaybeProgramLoc\x12+\n\x15suspended_assumptions\x18\x05 \x01(\x0b\x32\x0c.Assumptions\"^\n\x0b\x42ranchAbort\x12$\n\x0c\x61\x62ort_result\x18\x01 \x01(\x0b\x32\x0e.AbortedResult\x12)\n\x13\x61\x62orted_assumptions\x18\x02 \x01(\x0b\x32\x0c.Assumptions\"\'\n\x12ReturnFromFunction\x12\x11\n\tfunc_name\x18\x01 \x01(\t\"7\n\x0c\x43\x61llFunction\x12\x11\n\tfunc_name\x18\x01 \x01(\t\x12\x14\n\x0cis_tail_call\x18\x02 \x01(\x08\"\x11\n\x0fSolverPushFrame\"0\n\x0eSolverPopFrame\x12\x1e\n\rpath_id_after\x18\x01 \x01(\x0b\x32\x07.PathID\"H\n\x06\x41ssume\x12 \n\tpredicate\x18\x01 \x01(\x0b\x32\r.ExpressionID\x12\x1c\n\x0bnew_path_id\x18\x02 \x01(\x0b\x32\x07.PathID\"G\n\x05\x43heck\x12 \n\tpredicate\x18\x01 \x01(\x0b\x32\r.ExpressionID\x12\x1c\n\x0bnew_path_id\x18\x02 \x01(\x0b\x32\x07.PathID\"K\n\x13NewSymbolicVariable\x12\x0c\n\x04name\x18\x01 \x01(\t\x12&\n\nexpression\x18\x02 \x01(\x0b\x32\x12.AnyTypeExpression\"\xba\x03\n\nTraceEvent\x12\x18\n\x07path_id\x18\x01 \x01(\x0b\x32\x07.PathID\x12\"\n\x08location\x18\x02 \x01(\x0b\x32\x10.MaybeProgramLoc\x12 \n\npath_split\x18\x03 \x01(\x0b\x32\n.PathSplitH\x00\x12 \n\npath_merge\x18\x04 \x01(\x0b\x32\n.PathMergeH\x00\x12&\n\rbranch_switch\x18\x05 \x01(\x0b\x32\r.BranchSwitchH\x00\x12$\n\x0c\x62ranch_abort\x18\x06 \x01(\x0b\x32\x0c.BranchAbortH\x00\x12\x19\n\x06\x61ssume\x18\x07 \x01(\x0b\x32\x07.AssumeH\x00\x12\x33\n\x14return_from_function\x18\t \x01(\x0b\x32\x13.ReturnFromFunctionH\x00\x12&\n\rcall_function\x18\n \x01(\x0b\x32\r.CallFunctionH\x00\x12\x30\n\x10new_symbolic_var\x18\x0b \x01(\x0b\x32\x14.NewSymbolicVariableH\x00\x12$\n\x0cmemory_event\x18\x0c \x01(\x0b\x32\x0c.MemoryEventH\x00\x42\x0c\n\nevent_kind\"-\n\x0eOperationTrace\x12\x1b\n\x06\x65vents\x18\x01 \x03(\x0b\x32\x0b.TraceEventb\x06proto3')

_builder.BuildMessageAndEnumDescriptors(DESCRIPTOR, globals())
_builder.BuildTopDescriptorsAndMessages(DESCRIPTOR, 'crucible_protobuf_trace.operation_trace_pb2', globals())
if _descriptor._USE_C_DESCRIPTORS == False:

  DESCRIPTOR._options = None
  _ASSERTION._serialized_start=252
  _ASSERTION._serialized_end=314
  _PATHID._serialized_start=316
  _PATHID._serialized_end=338
  _PATHSPLIT._serialized_start=340
  _PATHSPLIT._serialized_end=428
  _PATHMERGE._serialized_start=431
  _PATHMERGE._serialized_end=654
  _BRANCHSWITCH._serialized_start=657
  _BRANCHSWITCH._serialized_end=860
  _BRANCHABORT._serialized_start=862
  _BRANCHABORT._serialized_end=956
  _RETURNFROMFUNCTION._serialized_start=958
  _RETURNFROMFUNCTION._serialized_end=997
  _CALLFUNCTION._serialized_start=999
  _CALLFUNCTION._serialized_end=1054
  _SOLVERPUSHFRAME._serialized_start=1056
  _SOLVERPUSHFRAME._serialized_end=1073
  _SOLVERPOPFRAME._serialized_start=1075
  _SOLVERPOPFRAME._serialized_end=1123
  _ASSUME._serialized_start=1125
  _ASSUME._serialized_end=1197
  _CHECK._serialized_start=1199
  _CHECK._serialized_end=1270
  _NEWSYMBOLICVARIABLE._serialized_start=1272
  _NEWSYMBOLICVARIABLE._serialized_end=1347
  _TRACEEVENT._serialized_start=1350
  _TRACEEVENT._serialized_end=1792
  _OPERATIONTRACE._serialized_start=1794
  _OPERATIONTRACE._serialized_end=1839
# @@protoc_insertion_point(module_scope)
