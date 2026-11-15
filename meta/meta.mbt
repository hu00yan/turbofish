// 元数据对象判定：这些 key 由元数据服务（metad）承载，查询路径不应回源 S3。
//
// 数据对象（segment 的 vec/ 分片、FTS postings、global IVF 向量分片）不在此列，
// 仍由查询节点直接向对象存储发起读取。

///|
/// 是否为可放入元数据服务的小对象。
pub fn is_metadata_key(key : String) -> Bool {
  if key.has_suffix("/_meta/namespace.json") {
    return true
  }
  if key.has_suffix("/_head_ptr") {
    return true
  }
  if key.contains("/_heads/") {
    return true
  }
  if key.contains("/_manifest/") && key.has_suffix(".json") {
    return true
  }
  if key.contains("/_centroids/") {
    return true
  }
  if key.contains("/_tombstones/") {
    return true
  }
  if key.contains("/_segments/") {
    return key.has_suffix("/meta.json") ||
      key.contains("/rows/") ||
      key.has_suffix("/fts/dir.bin") ||
      key.has_suffix("/fts/doc_len.bin") ||
      key.has_suffix("/fts/blockmax.bin")
  }
  if key.contains("/vec/global/") && key.has_suffix("/meta.json") {
    return true
  }
  false
}

///|
/// 元数据服务的 HTTP 路径前缀。
pub const METAD_KV_PREFIX : String = "/kv/"
