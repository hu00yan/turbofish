// MergeTree 引擎核心：紧凑 Part 读写、L0 Delta Part 追加路径、Roaring Bitmap 墓碑过滤、Range GET。

///|
pub struct MergeTreeEngine[S] {
  store : S
  ns : String
  part_store : ObjPartStore[S]
  manifest_store : ObjManifestStore[S]
  dim : Int
  use_f16 : Bool
  centroids : @format.Centroids?
  mut manifest : Manifest
}

///|
pub fn[S : @store.ObjectStore] MergeTreeEngine::new(
  store : S,
  ns : String,
  dim : Int,
  use_f16 : Bool,
  centroids : @format.Centroids?
) -> MergeTreeEngine[S] raise @core.SpndError {
  let part_store = ObjPartStore::new(store, ns)
  let manifest_store = ObjManifestStore::new(store, ns)
  let manifest = ManifestStore::load(manifest_store)
  {
    store,
    ns,
    part_store,
    manifest_store,
    dim,
    use_f16,
    centroids,
    manifest,
  }
}

///|
pub fn[S] MergeTreeEngine::get_manifest(self : MergeTreeEngine[S]) -> Manifest {
  self.manifest
}

///|
/// 追加基线 Part（Level = 1）。
/// 仅产生 1 次 Part S3 PUT。
pub fn[S : @store.ObjectStore] MergeTreeEngine::append_base_part(
  self : MergeTreeEngine[S],
  docs : Array[@core.Doc]
) -> String raise @core.SpndError {
  self.append_part_internal(docs, 1)
}

///|
/// 追加 L0 Delta Part（Level = 0，Cursor/Notion 增量写入）。
/// 打包全部列、倒排和向量切片至单个紧凑 Part 文件，仅产生 1 次 S3 PUT
pub fn[S : @store.ObjectStore] MergeTreeEngine::append_l0_delta_part(
  self : MergeTreeEngine[S],
  docs : Array[@core.Doc]
) -> String raise @core.SpndError {
  self.append_part_internal(docs, 0)
}

///|
fn[S : @store.ObjectStore] MergeTreeEngine::append_part_internal(
  self : MergeTreeEngine[S],
  docs : Array[@core.Doc],
  level : Int
) -> String raise @core.SpndError {
  if docs.is_empty() {
    raise @core.Corrupt("cannot append empty doc batch")
  }
  let mut min_id = docs[0].id
  let mut max_id = docs[0].id
  for d in docs {
    if d.id < min_id {
      min_id = d.id
    }
    if d.id > max_id {
      max_id = d.id
    }
  }

  // 1. 打包并编码为单文件紧凑 Part (SPNDFOOT/CPT1)
  let (compact_bytes, _) = @format.encode_compact_part(
    docs,
    self.dim,
    self.use_f16,
    self.centroids,
  )

  // 2. PUT 到 PartStore（确切只产生 1 次 S3 PUT 请求！）
  let part_id = PartStore::put_part(self.part_store, compact_bytes)

  // 3. 构造 Part 元数据并登记到 manifest
  let meta : PartMeta = {
    part_id,
    level,
    row_count: docs.length(),
    min_id,
    max_id,
    size_bytes: compact_bytes.length(),
    tombstone_count: 0,
  }
  self.manifest.parts.push(meta)
  part_id
}

///|
/// 变更新增（10-row edit）：
/// 1. 软删除被修改的旧行（追加到 tombstone 集合，由 Roaring Bitmap 掩码屏蔽）；
/// 2. 将修改后的新数据打包为单一 L0 Delta Part 写入存储（仅 1 次 S3 PUT，零改动基线数据）；
/// 3. 返回新生成的 delta part id。
pub fn[S : @store.ObjectStore] MergeTreeEngine::mutate_rows(
  self : MergeTreeEngine[S],
  updated_docs : Array[@core.Doc],
  old_ids : Array[UInt64]
) -> String raise @core.SpndError {
  let updated_ids : Set[UInt64] = Set([])
  for d in updated_docs {
    updated_ids.add(d.id)
  }
  let to_delete : Array[UInt64] = Array()
  for id in old_ids {
    if !updated_ids.contains(id) {
      to_delete.push(id)
    }
  }
  if !to_delete.is_empty() {
    self.soft_delete(to_delete)
  }

  // 2. 将新行写入新的 L0 Delta Part（仅 1 个 S3 PUT）
  self.append_l0_delta_part(updated_docs)
}

///|
/// 软删除：将待删除的 doc id 登记到 Manifest 的 tombstones 列表中并去重排序，同时累加各 Part 的 tombstone_count。
pub fn[S] MergeTreeEngine::soft_delete(
  self : MergeTreeEngine[S],
  ids : Array[UInt64]
) -> Unit {
  let existing : Set[UInt64] = Set([])
  for id in self.manifest.tombstones {
    existing.add(id)
  }
  for id in ids {
    if !existing.contains(id) {
      existing.add(id)
      self.manifest.tombstones.push(id)
    }
  }
  self.manifest.tombstones.sort()

  // 更新各 Base Part 的 tombstone 统计
  for p in self.manifest.parts {
    if p.level > 0 {
      let mut cnt = 0
      for id in self.manifest.tombstones {
        if id >= p.min_id && id <= p.max_id {
          cnt += 1
        }
      }
      p.tombstone_count = cnt
    }
  }
}

///|
/// 发布 Manifest 状态。
pub fn[S : @store.ObjectStore] MergeTreeEngine::publish_manifest(
  self : MergeTreeEngine[S]
) -> Unit raise @core.SpndError {
  self.manifest.seq += 1UL
  ManifestStore::publish(self.manifest_store, self.manifest)
}

///|
/// 通过 Range GET 读取 Part 的 Footer（Mark Index）。
/// 读路径：先 Range GET 末尾 16 字节 Trailer -> 解析 footer 位置 -> Range GET Footer 字节 -> 解析 sections。
pub fn[S : @store.ObjectStore] MergeTreeEngine::read_part_footer(
  self : MergeTreeEngine[S],
  meta : PartMeta
) -> @format.CompactFooter raise @core.SpndError {
  // 1. Range GET Trailer (末尾 16 字节)
  let trailer_slice = match
    PartStore::get_part_range(
      self.part_store,
      meta.part_id,
      meta.size_bytes - @format.COMPACT_TRAILER_LEN,
      @format.COMPACT_TRAILER_LEN,
    ) {
    Some(b) => b
    None =>
      raise @core.NotFound("missing part trailer for \{meta.part_id}")
  }
  let (footer_off, footer_len) = @format.decode_compact_part_trailer(
    trailer_slice,
  )

  // 2. Range GET Footer (精确切片)
  let footer_slice = match
    PartStore::get_part_range(self.part_store, meta.part_id, footer_off, footer_len) {
    Some(b) => b
    None =>
      raise @core.NotFound("missing part footer for \{meta.part_id}")
  }
  @format.decode_compact_part_footer(footer_slice, 0, footer_len)
}

///|
/// 通过 Range GET 精确读取 Part 的指定 Section（例如单一列或倒排目录）。
pub fn[S : @store.ObjectStore] MergeTreeEngine::read_part_section(
  self : MergeTreeEngine[S],
  meta : PartMeta,
  sec : @format.CompactSection
) -> Bytes raise @core.SpndError {
  match PartStore::get_part_range(self.part_store, meta.part_id, sec.offset, sec.length) {
    Some(b) => b
    None =>
      raise @core.NotFound(
        "missing section \{sec.name} in part \{meta.part_id}",
      )
  }
}

///|
/// 读取并重构当前所有活文档（过滤墓碑遮蔽与去重最新版本）。
pub fn[S : @store.ObjectStore] MergeTreeEngine::read_live_docs(
  self : MergeTreeEngine[S]
) -> Array[@core.Doc] raise @core.SpndError {
  let roar_mask = self.manifest.tombstone_mask()
  let live : Array[@core.Doc] = Array()
  let seen_ids : Set[UInt64] = Set([])

  // 从最新的 Part 到最旧的 Part 遍历（最新 L0 优先）
  let mut p_idx = self.manifest.parts.length() - 1
  while p_idx >= 0 {
    let meta = self.manifest.parts[p_idx]
    let footer = self.read_part_footer(meta)
    let full_part = match PartStore::get_part(self.part_store, meta.part_id) {
      Some(b) => b
      None => raise @core.NotFound("part not found: \{meta.part_id}")
    }
    let docs = @format.decode_compact_part_docs(full_part, footer)
    for d in docs {
      if !@format.roaring_contains(roar_mask, d.id) {
        if !seen_ids.contains(d.id) {
          seen_ids.add(d.id)
          live.push(d)
        }
      }
    }
    p_idx -= 1
  }

  // 恢复升序按 id 排序（便于比对验证）
  live.sort_by(fn(a, b) {
    if a.id < b.id {
      -1
    } else if a.id > b.id {
      1
    } else {
      0
    }
  })
  live
}
