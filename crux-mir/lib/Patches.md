# Patching the Rust standard library

This directory bundles a copy of the Rust standard library with various patches
applied in certain key places to make the resulting code easier for Crucible to
handle. These patches must be applied every time that the bundled Rust standard
library is updated. Moreover, this code often looks quite different each time
between Rust versions, so applying the patches is rarely as straightforward as
running `git apply`.

As a compromise, this document contains high-level descriptions of each type of
patch that we apply, along with rationale for why the patch is necessary. The
intent is that this document can be used in conjunction with `git blame` to
identify all of the code that was changed in each patch.

* Use Crucible's allocator in `alloc/src/raw_vec.rs` (last applied: April 14, 2023)

  The `Allocator` for `RawVec`s is quite involved and is beyond Crucible's
  ability to reason about. We replace the `Allocator` with the corresponding
  built-in Crucible allocation functions (e.g., `crucible::alloc::allocate`).
  We also make sure to avoid the `Layout::array` function, which has a
  particularly tricky use of `transmute` that we do not currently support.