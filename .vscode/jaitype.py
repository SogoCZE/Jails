# https://github.com/rluba/lldb-jai

DEBUG = 0
USE_CMDS = 1

MAX_STRING_LEN = 1024

import lldb
if DEBUG:
  import debugpy


def String( valobj: lldb.SBValue, internal_dict, options ):
  data: lldb.SBValue = valobj.GetChildMemberWithName( 'data' )
  len = valobj.GetChildMemberWithName( 'count' ).GetValueAsSigned( 0 )
  if len == 0:
    return ""
  if len < 0:
    return "invalid length (" + str( len ) + ")"
  if len > 0xFFFFFFFF:
    return "length is too big for LLDB's puny python bridge (" + str( len ) + ")"

  # FIXME: This might actually chomp the middle of a unicode character, so we
  # should do a fixup for that (scan backwards for the previous non-continuation
  # byte
  len_to_decode = min( len, MAX_STRING_LEN )
  # HACK: Assume it's utf-8.... I wonder if options contains an encoding option?
  return ( '"'
           + bytes( data.GetPointeeData( 0, len_to_decode ).uint8s ).decode( 'utf-8' )
           + '"' )


# Annoyingly summary strings suppress the printing of the child members by
# default. This is crappy, and means we have to write that code ourselves, but
# it's not even that trivial as just printing the "GetValue()" of each child
# prints "None", helpfully.
def Array( valobj: lldb.SBValue, internal_dict, options ):
  raw: lldb.SBValue = valobj.GetNonSyntheticValue()
  return ( "Array(count="
           + str( raw.GetChildMemberWithName( 'count' ).GetValueAsSigned() )
           + ")" )


def ResizableArray( valobj: lldb.SBValue, internal_dict, options ):
  raw: lldb.SBValue = valobj.GetNonSyntheticValue()
  data = raw.GetChildMemberWithName( 'data' ).GetValueAsSigned()
  return ( "Array(count="
           + str( raw.GetChildMemberWithName( 'count' ).GetValueAsSigned() )
           + ",allocated="
           + str( raw.GetChildMemberWithName( 'allocated' ).GetValueAsSigned() )
           + ")" )


class ArrayChildrenProvider:
  def __init__( self, valobj: lldb.SBValue, internal_dict ):
    self.val = valobj
    self.native = ["count", "data"]

  def update( self ):
    self.count = self.val.GetChildMemberWithName( 'count' ).GetValueAsSigned()
    self.data: lldb.SBValue = self.val.GetChildMemberWithName( 'data' )
    self.data_type: lldb.SBType = self.data.GetType().GetPointeeType()
    self.data_size = self.data_type.GetByteSize()

    return False

  def has_children( self ):
    return True

  def num_children(self):
    return len(self.native) + self.count;

  def get_child_index(self, name):
    try:
      return self.native.index(name)
    except ValueError:
      return len(self.native) + int( name )

  def get_child_at_index(self, child_index):
    if child_index < len(self.native):
      return self.val.GetChildMemberWithName(self.native[child_index])
      
    index = child_index - len(self.native);
    return self.data.CreateChildAtOffset( '[' + str(index) + ']',
                                          self.data_size * index,
                                          self.data_type )


class ResizableArrayChildrenProvider(ArrayChildrenProvider):
  def __init__( self, valobj: lldb.SBValue, internal_dict):
    ArrayChildrenProvider.__init__(self, valobj, internal_dict)
    self.native = ["count", "data", "allocated", "allocator"]


def __lldb_init_module( debugger: lldb.SBDebugger, dict ):
  if DEBUG:
    debugpy.listen( 5432 )
    debugpy.wait_for_client()

  C = debugger.HandleCommand
  C(  "type summary add    -w Jai string -F jaitype.String" )
  C( r"type summary add -e -w Jai -x '\[\] .*'     -F jaitype.Array" )
  C( r"type summary add -e -w Jai -x '\[\.\.\] .*' -F jaitype.ResizableArray" )
  C( r"type synthetic add  -w Jai -x '\[\] .*'     -l jaitype.ArrayChildrenProvider" )
  C( r"type synthetic add  -w Jai -x '\[\.\.\] .*' -l jaitype.ResizableArrayChildrenProvider" )
  C(  'type category enable Jai' )
