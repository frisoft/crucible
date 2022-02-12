# next

* Separate backend data structures.  The "symbolic backend" is a
ubiquitous datatype throughout Crucible. Previously, this single
data structure was responsible for symbolic expression creation
and also for tracking the structure of assumptions and assertions
as the symbolic simulator progresses. These linked purposes made
certain code patterns very difficult, such as running related symbolic
simulation instances in separate threads, or configuring different
online solvers for path satisfiability checking.

We changed this structure so that the `sym` value is now only
responsible for the What4 expression creation tasks.  Now, there is a
new "symbolic backend" `bak` value (that contains a `sym`) which is
used to handle path conditions and assertions.  These two values are
connected by the `IsSymBackend sym bak` type class.  To prevent even
more code churn than is already occurring, the exact type of `bak` is
wrapped up into an existential datatype and stored in the
`SimContext`. This makes accessing the symbolic backend a little less
convenient, but prevents the new type from leaking into every type
signature that currently mentions `sym`.  The `withBackend`
and `ovrWithBackend` operations (written in a CPS style) are the
easiest way to get access to the backend, but it can also be accessed
via directly pattern matching on the existential `SomeBackend` type.

For many purposes the old `sym` value is still sufficient, and the
`bak` value is not necessary. A good rule is that any operation
that adds assumptions or assertions to the context will need
the full symbolic backend `bak`, but any operation that just
builds terms will only need the `sym`.