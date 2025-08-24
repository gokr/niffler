## Diff Types Module
##
## Provides common types for diff visualization.

type
  DiffLineType* = enum
    Context, Added, Removed, Header
  
  DiffSegmentType* = enum
    ## Types of segments within a diff line
    Unchanged,     # Part of line that didn't change
    AddedSegment,  # Part of line that was added
    RemovedSegment # Part of line that was removed
  
  DiffSegment* = object
    ## A segment within a diff line with its own styling
    content*: string
    segmentType*: DiffSegmentType
  
  InlineDiffLine* = object
    ## A diff line with inline segment-level highlighting
    lineType*: DiffLineType
    segments*: seq[DiffSegment]
    originalLineNum*: int  # -1 if not applicable
    newLineNum*: int       # -1 if not applicable