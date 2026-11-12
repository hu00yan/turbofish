// MoonBit Formal Specification & Verification Contracts: MergeTree Invariants.
// Formalizes live document preservation under soft deletion and compaction:
// A doc is live iff it exists in at least one part AND is not present in tombstone mask.

///|
#derive(Debug, Eq)
pub(all) struct SpecPart {
  part_id : String
  level : Int // 0 = L0 delta, 1 = consolidated base
  ids : Array[UInt64]
  min_id : UInt64
  max_id : UInt64
}

///|
#derive(Debug, Eq)
pub(all) struct SpecMergeTree {
  parts : Array[SpecPart]
  tombstones : Array[UInt64]
}

///|
/// Checks if an ID falls within a part's range bounds.
#proof_pure
pub fn id_in_part_bounds(id : UInt64, min_id : UInt64, max_id : UInt64) -> Bool {
  id >= min_id && id <= max_id
}

///|
/// Core live predicate truth table:
/// A document is live if present in parts and NOT marked as tombstone.
#proof_pure
pub fn eval_doc_liveness(in_parts : Bool, in_tombstones : Bool) -> Bool {
  in_parts && !in_tombstones
}

///|
/// Pure contract: Liveness evaluation matches core invariant.
pub fn check_doc_liveness(in_parts : Bool, in_tombstones : Bool) -> Bool where {
  proof_ensure: result => result == (in_parts && !in_tombstones),
} {
  eval_doc_liveness(in_parts, in_tombstones)
}

///|
/// Checks if a part contains an ID.
pub fn part_contains_id(part : SpecPart, id : UInt64) -> Bool {
  if !id_in_part_bounds(id, part.min_id, part.max_id) {
    return false
  }
  let n = part.ids.length()
  for i in 0..<n {
    if part.ids[i] == id {
      return true
    }
  }
  false
}

///|
/// Checks if at least one part contains an ID.
pub fn parts_contain_id(parts : Array[SpecPart], id : UInt64) -> Bool {
  let n = parts.length()
  for i in 0..<n {
    if part_contains_id(parts[i], id) {
      return true
    }
  }
  false
}

///|
/// Checks if an ID is present in the tombstone list.
pub fn tombstones_contain_id(tombstones : Array[UInt64], id : UInt64) -> Bool {
  let n = tombstones.length()
  for i in 0..<n {
    if tombstones[i] == id {
      return true
    }
  }
  false
}

///|
/// MergeTree Invariant:
/// A document is LIVE if and only if it exists in at least one part
/// AND is NOT present in tombstones.
pub fn doc_is_live(tree : SpecMergeTree, id : UInt64) -> Bool {
  eval_doc_liveness(
    parts_contain_id(tree.parts, id),
    tombstones_contain_id(tree.tombstones, id),
  )
}

///|
/// Soft delete transition:
/// Adds target IDs to tombstones list and sorts them.
/// Invariant: Any ID in deleted_ids is guaranteed NOT live in result.
pub fn apply_soft_delete(
  tree : SpecMergeTree,
  deleted_ids : Array[UInt64]
) -> SpecMergeTree {
  let new_tombs = tree.tombstones.copy()
  let del_len = deleted_ids.length()
  for i in 0..<del_len {
    let id = deleted_ids[i]
    if !tombstones_contain_id(new_tombs, id) {
      new_tombs.push(id)
    }
  }
  new_tombs.sort()
  { parts: tree.parts, tombstones: new_tombs }
}

///|
/// Append L0 Delta Part transition:
/// Adds a new delta part without touching existing parts or tombstones.
pub fn apply_append_l0(
  tree : SpecMergeTree,
  part_id : String,
  new_ids : Array[UInt64]
) -> SpecMergeTree {
  if new_ids.is_empty() {
    return tree
  }
  let mut min_id = new_ids[0]
  let mut max_id = new_ids[0]
  let n = new_ids.length()
  for i in 0..<n {
    let id = new_ids[i]
    if id < min_id {
      min_id = id
    }
    if id > max_id {
      max_id = id
    }
  }
  let new_part : SpecPart = {
    part_id,
    level: 0,
    ids: new_ids,
    min_id,
    max_id,
  }
  let new_parts = tree.parts.copy()
  new_parts.push(new_part)
  { parts: new_parts, tombstones: tree.tombstones }
}

///|
/// Compaction transition:
/// Merges parts, physicalizes tombstones (purging deleted IDs),
/// and guarantees that the set of live documents is 100% PRESERVED.
/// `forall id, doc_is_live(result, id) == doc_is_live(tree, id)`.
pub fn apply_compaction(
  tree : SpecMergeTree,
  new_base_part_id : String
) -> SpecMergeTree {
  let live_ids : Array[UInt64] = Array::new()
  let num_parts = tree.parts.length()
  for p_idx in 0..<num_parts {
    let p = tree.parts[p_idx]
    let p_len = p.ids.length()
    for i in 0..<p_len {
      let id = p.ids[i]
      if !tombstones_contain_id(tree.tombstones, id) {
        if !tombstones_contain_id(live_ids, id) {
          live_ids.push(id)
        }
      }
    }
  }
  live_ids.sort()

  let min_id = if live_ids.is_empty() { 0UL } else { live_ids[0] }
  let max_id = if live_ids.is_empty() { 0UL } else { live_ids[live_ids.length() - 1] }

  let base_part : SpecPart = {
    part_id: new_base_part_id,
    level: 1,
    ids: live_ids,
    min_id,
    max_id,
  }

  { parts: [base_part], tombstones: [] }
}

///|
/// Inductive Invariant Check: Live doc equivalence between pre- and post-compaction.
pub fn verify_compaction_live_doc_preservation(
  before : SpecMergeTree,
  after : SpecMergeTree,
  universe_ids : Array[UInt64]
) -> Bool {
  let n = universe_ids.length()
  for i in 0..<n {
    let id = universe_ids[i]
    let was_live = doc_is_live(before, id)
    let is_live = doc_is_live(after, id)
    if was_live != is_live {
      return false
    }
  }
  true
}
