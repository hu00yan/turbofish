// 条件唤醒策略（spec 要求）：
// 1) 仅当 L0 delta part 数量超过阈值（如 >= 4）或 segment 中 tombstone 比例超过 20% 时触发合并；
// 2) 辅以 idle timer fallback 空闲回退；
// 3) 绝不在 S3 上死循环 LIST/HEAD。

///|
pub(all) struct CompactionTriggerConfig {
  l0_threshold : Int // 默认 4
  tombstone_ratio_threshold : Double // 默认 0.20 (20%)
  idle_fallback_ms : Int64 // 默认 30000 毫秒
  max_merge_parts : Int // 单次合并最大分段数
} derive(Debug, Eq)

///|
pub fn CompactionTriggerConfig::default() -> CompactionTriggerConfig {
  {
    l0_threshold: 4,
    tombstone_ratio_threshold: 0.20,
    idle_fallback_ms: 30000L,
    max_merge_parts: 16,
  }
}

///|
/// 判断是否满足合并唤醒条件。
/// 必须由写事件通知或空闲定时器驱动，严禁外部通过轮询 S3 LIST 调用。
pub fn should_trigger_compaction(
  manifest : Manifest,
  idle_elapsed_ms : Int64,
  config : CompactionTriggerConfig,
) -> Bool {
  // 1. 统计 L0 delta 数量
  if manifest.l0_count() >= config.l0_threshold {
    return true
  }

  // 2. 检查单 segment (base part) 内 tombstone 比例是否超过阈值（20%）
  for p in manifest.parts {
    if p.level > 0 && manifest.tombstone_ratio(p) >= config.tombstone_ratio_threshold {
      return true
    }
  }

  // 检查全局 tombstone 比例是否超过 20%
  let total_rows = manifest.total_rows()
  if total_rows > 0 && manifest.tombstones.length() > 0 {
    let global_ratio = manifest.tombstones.length().to_double() /
      total_rows.to_double()
    if global_ratio >= config.tombstone_ratio_threshold {
      return true
    }
  }

  // 3. 空闲超时兜底 (Idle timer fallback)
  // 当系统处于空闲且存在待合并的 L0 delta 或待清理的 tombstone 时触发
  if idle_elapsed_ms >= config.idle_fallback_ms {
    if manifest.l0_count() > 0 || manifest.tombstones.length() > 0 {
      return true
    }
  }

  false
}

///|
/// 基于大小分层与条件唤醒的 MergePolicy 实现。
pub(all) struct TieredMergePolicy {
  config : CompactionTriggerConfig
} derive(Debug, Eq)

///|
pub fn TieredMergePolicy::new(
  config : CompactionTriggerConfig,
) -> TieredMergePolicy {
  { config, }
}

///|
pub impl MergePolicy for TieredMergePolicy with pick(
  self : TieredMergePolicy,
  parts : Array[PartMeta],
) -> Array[String]? {
  let l0_parts : Array[PartMeta] = Array::new()
  let base_parts : Array[PartMeta] = Array::new()
  let mut tombstone_triggered = false

  for p in parts {
    if p.level == 0 {
      l0_parts.push(p)
    } else {
      base_parts.push(p)
    }
    if p.level > 0 && p.row_count > 0 {
      let r = p.tombstone_count.to_double() / p.row_count.to_double()
      if r >= self.config.tombstone_ratio_threshold {
        tombstone_triggered = true
      }
    }
  }

  let l0_triggered = l0_parts.length() >= self.config.l0_threshold

  // 收集待合并的 part_id
  let picked : Array[String] = Array::new()

  // 如果满足触发条件，或者只要存在待折叠的 L0 增量段，则打包基线与 delta
  if l0_triggered || tombstone_triggered || l0_parts.length() > 0 {
    for p in base_parts {
      picked.push(p.part_id)
    }
    for p in l0_parts {
      picked.push(p.part_id)
      if picked.length() >= self.config.max_merge_parts {
        break
      }
    }
  }

  if picked.is_empty() {
    None
  } else {
    Some(picked)
  }
}
