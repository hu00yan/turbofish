// turbofish 多进程集群监管器（supervise）。
//
// 一个进程里拉起并托管整条本地集群：
//   metad                         元数据服务（租约 + 脏队列 + bundle）
//   compactd                      后台合并守护（从 metad 领脏队列）
//   serve-0 .. serve-(N-1)        查询/写入 worker
//
// 关键点：
//   - worker 的 namespace → writer owner 归属是**纯函数**（FNV-1a 64 % N），
//     任何进程都能算出一致结果，不需要额外协调（见 writer_owner_for_ns）。
//   - 每个 worker 有独立内部端口（worker_internal_port），用于 worker 间转发。
//   - 子进程崩溃由 probe 循环自动重启（带指数退避），
//   - 收到 SIGINT/SIGTERM 时优雅终止整组子进程（SIGTERM → 超时 SIGKILL）。
//
// 环境变量：
//   SPND_WORKERS                 serve 子进程个数，默认 2
//   SPND_PORT_BASE               serve 监听端口基数，默认 SPND_PORT 或 8080
//   SPND_INTERNAL_BASE_PORT      worker 内部端口基数，默认 19080
//   SPND_META_URL                metad 地址，默认 http://127.0.0.1:8090
//   SPND_META_PORT               metad 监听端口，默认 8090
//   SPND_META_DIR                metad 本地目录
//   SPND_METAD_BIN               metad 可执行文件，默认 metad
//   SPND_COMPACD_BIN             compactd 可执行文件，默认 compactd
//   SPND_SERVE_BIN               serve 可执行文件，默认 serve
//   SPND_SUPERVISE_METAD         1/0，是否托管 metad，默认 1
//   SPND_SUPERVISE_COMPACD       1/0，是否托管 compactd，默认 1
//   SPND_SUPERVISE_PROBE_MS      probe 周期，默认 1000
//   SPND_SUPERVISE_GRACEFUL_MS   优雅退出超时，默认 5000

///|
fn env_or(key : String, dflt : String) -> String {
  match @env.get_env_var(key) {
    Some(v) => if v.trim() == "" { dflt } else { v }
    None => dflt
  }
}

///|
fn env_int(key : String, dflt : Int) -> Int {
  let raw = env_or(key, dflt.to_string()).trim()
  @string.parse_int(raw, base=10) catch {
    _ => dflt
  }
}

///|
fn env_flag(key : String, dflt : Bool) -> Bool {
  let raw = env_or(key, if dflt { "1" } else { "0" }).trim()
  raw == "1" || raw.to_lower() == "true" || raw.to_lower() == "yes"
}

// ---------- 纯函数路由（可在任意进程复现） ----------

///|
/// FNV-1a 64-bit（UTF-8 字节）。
pub fn fnv1a64(s : String) -> UInt64 {
  let b = Buffer()
  b.write_string_utf8(s)
  let bs = b.to_bytes()
  let mut h : UInt64 = 0xcbf29ce484222325UL
  for i in 0..<bs.length() {
    h = h ^ bs[i].to_uint64()
    h = h * 0x100000001b3UL
  }
  h
}

///|
/// namespace 的写者归属（确定性 FNV-1a 64-bit hash % worker_count）。
/// `worker_count <= 1` 时恒为 0。
pub fn writer_owner_for_ns(ns : String, worker_count : Int) -> Int {
  if worker_count <= 1 {
    return 0
  }
  (fnv1a64(ns) % worker_count.to_uint64()).to_int()
}

///|
/// worker 的内部端口（用于 worker 间转发）：base + worker_id。
pub fn worker_internal_port(
  base_internal_port : Int,
  worker_id : Int,
) -> Int {
  if worker_id < 0 {
    base_internal_port
  } else {
    base_internal_port + worker_id
  }
}

///|
/// worker 的外部服务端口：base + worker_id。
pub fn worker_serve_port(serve_port_base : Int, worker_id : Int) -> Int {
  if worker_id < 0 {
    serve_port_base
  } else {
    serve_port_base + worker_id
  }
}

// ---------- 配置 ----------

///|
pub struct SupervisorConfig {
  workers : Int
  serve_port_base : Int
  internal_base_port : Int
  meta_url : String
  meta_port : String
  meta_dir : String
  metad_bin : String
  metad_enabled : Bool
  compactd_bin : String
  compactd_enabled : Bool
  serve_bin : String
  probe_ms : Int
  graceful_ms : Int
}

///|
pub fn SupervisorConfig::from_env() -> SupervisorConfig {
  let workers = {
    let n = env_int("SPND_WORKERS", 2)
    if n < 0 {
      0
    } else {
      n
    }
  }
  let serve_port_base = env_int(
    "SPND_PORT_BASE",
    env_int("SPND_PORT", 8080),
  )
  let meta_port = env_or("SPND_META_PORT", "8090")
  {
    workers,
    serve_port_base,
    internal_base_port: env_int("SPND_INTERNAL_BASE_PORT", 19080),
    meta_url: env_or("SPND_META_URL", "http://127.0.0.1:\{meta_port}"),
    meta_port,
    meta_dir: env_or("SPND_META_DIR", "/tmp/turbofish-metad"),
    metad_bin: env_or("SPND_METAD_BIN", "metad"),
    metad_enabled: env_flag("SPND_SUPERVISE_METAD", true),
    compactd_bin: env_or("SPND_COMPACD_BIN", "compactd"),
    compactd_enabled: env_flag("SPND_SUPERVISE_COMPACD", true),
    serve_bin: env_or("SPND_SERVE_BIN", "serve"),
    probe_ms: env_int("SPND_SUPERVISE_PROBE_MS", 1000),
    graceful_ms: env_int("SPND_SUPERVISE_GRACEFUL_MS", 5000),
  }
}

// ---------- 子进程 ----------

///|
/// 一个待托管的子进程描述。
pub struct ChildSpec {
  name : String
  bin : String
  args : Array[String]
  env : Map[String, String]
}

///|
/// 构建整条集群的子进程描述（纯函数，便于测试/预览）。
pub fn build_specs(config : SupervisorConfig) -> Array[ChildSpec] {
  let specs : Array[ChildSpec] = []
  if config.metad_enabled {
    let env : Map[String, String] = Map([])
    env.set("SPND_META_PORT", config.meta_port)
    env.set("SPND_META_DIR", config.meta_dir)
    specs.push({ name: "metad", bin: config.metad_bin, args: [], env })
  }
  if config.compactd_enabled {
    let env : Map[String, String] = Map([])
    env.set("SPND_META_URL", config.meta_url)
    env.set("SPND_COMPACD_HOLDER", "compactd-0")
    specs.push({ name: "compactd", bin: config.compactd_bin, args: [], env })
  }
  for i in 0..<config.workers {
    let env : Map[String, String] = Map([])
    env.set("SPND_WORKER_ID", i.to_string())
    env.set("SPND_WORKER_COUNT", config.workers.to_string())
    env.set("SPND_INTERNAL_BASE_PORT", config.internal_base_port.to_string())
    env.set(
      "SPND_INTERNAL_PORT",
      worker_internal_port(config.internal_base_port, i).to_string(),
    )
    env.set("SPND_PORT", worker_serve_port(config.serve_port_base, i).to_string())
    env.set("SPND_META_URL", config.meta_url)
    specs.push({ name: "serve-\{i}", bin: config.serve_bin, args: [], env })
  }
  specs
}

///|
/// 一个托管槽位：描述 + 当前进程句柄 + 重启统计。
pub struct ChildSlot {
  spec : ChildSpec
  mut proc : @process.Process?
  mut restarts : Int
  mut last_exit : Int
  mut next_retry_ms : UInt64
}

///|
/// 重启退避（毫秒）：1s → 2s → 4s → ... 上限 30s。
fn backoff_ms(restarts : Int) -> Int {
  let mut delay = 1000
  let mut i = 0
  while i < restarts && delay < 30000 {
    delay = delay * 2
    i += 1
  }
  if delay > 30000 {
    30000
  } else {
    delay
  }
}

///|
/// 多进程监管器。
pub struct Supervisor {
  config : SupervisorConfig
  group : @async.TaskGroup[Unit]
  children : Array[ChildSlot]
  mut shutting_down : Bool
}

///|
pub fn Supervisor::new(
  group : @async.TaskGroup[Unit],
  config : SupervisorConfig,
) -> Supervisor {
  let children : Array[ChildSlot] = []
  for spec in build_specs(config) {
    children.push({
      spec,
      proc: None,
      restarts: 0,
      last_exit: 0,
      next_retry_ms: 0UL,
    })
  }
  { config, group, children, shutting_down: false }
}

///|
/// 启动（或重启）一个槽位。
async fn Supervisor::spawn_child(
  self : Supervisor,
  slot : ChildSlot,
) -> Unit {
  let args : Array[String] = slot.spec.args
  let attempt : Result[@process.Process, Error] = try {
    Ok(
      @process.spawn(
        self.group,
        slot.spec.bin,
        args,
        extra_env=slot.spec.env,
        inherit_env=true,
        cancel_handler=@process.graceful_cancel(
          timeout=self.config.graceful_ms,
        ),
        no_wait=true,
      ),
    )
  } catch {
    e => Err(e)
  }
  match attempt {
    Ok(p) => {
      slot.proc = Some(p)
      slot.next_retry_ms = 0UL
      if slot.restarts == 0 {
        println("[supervise] started \{slot.spec.name} (pid=\{p.pid})")
      } else {
        println(
          "[supervise] restarted \{slot.spec.name} (pid=\{p.pid}, restarts=\{slot.restarts})",
        )
      }
    }
    Err(e) => {
      slot.proc = None
      slot.restarts += 1
      slot.next_retry_ms = @env.now() +
        backoff_ms(slot.restarts).to_uint64()
      println(
        "[supervise] failed to start \{slot.spec.name} (\{slot.spec.bin}): \{e}",
      )
    }
  }
}

///|
/// 启动全部子进程。
pub async fn Supervisor::start_all(self : Supervisor) -> Unit {
  for slot in self.children {
    self.spawn_child(slot)
  }
}

///|
/// 周期性探测：回收已退出进程并自动重启（带退避）。
pub async fn Supervisor::reap_and_restart(self : Supervisor) -> Unit {
  let now = @env.now()
  for slot in self.children {
    let mut need_spawn = false
    match slot.proc {
      Some(p) => {
        let status : Int? = try {
          p.try_wait()
        } catch {
          _ => None
        }
        match status {
          Some(code) => {
            println(
              "[supervise] \{slot.spec.name} exited (code=\{code}), scheduling restart",
            )
            slot.proc = None
            slot.last_exit = code
            slot.restarts += 1
            slot.next_retry_ms = now + backoff_ms(slot.restarts).to_uint64()
            need_spawn = true
          }
          None => ()
        }
      }
      None => need_spawn = true
    }
    if need_spawn && now >= slot.next_retry_ms {
      self.spawn_child(slot)
    }
  }
}

///|
/// 监管主循环：直到被取消（收到退出信号）。
pub async fn Supervisor::run(self : Supervisor) -> Unit {
  self.start_all()
  while !self.shutting_down {
    @async.sleep(self.config.probe_ms)
    self.reap_and_restart()
  }
}

///|
/// 优雅终止整组子进程：每个子进程先 SIGTERM，超时后 SIGKILL。
pub async fn Supervisor::stop_all(self : Supervisor) -> Unit {
  self.shutting_down = true
  for slot in self.children {
    match slot.proc {
      Some(p) => {
        println("[supervise] stopping \{slot.spec.name} (pid=\{p.pid})")
        p.cancel()
      }
      None => ()
    }
  }
  for slot in self.children {
    match slot.proc {
      Some(p) => {
        let _ = try {
          p.wait()
        } catch {
          _ => 0
        }
        slot.proc = None
      }
      None => ()
    }
  }
  println("[supervise] all children stopped")
}

///|
/// 打印一次集群拓扑（不含子进程）。
pub fn print_plan(config : SupervisorConfig) -> Unit {
  println(
    "[supervise] workers=\{config.workers} serve_port_base=\{config.serve_port_base} internal_base=\{config.internal_base_port} meta=\{config.meta_url}",
  )
  for spec in build_specs(config) {
    let mut env_desc = ""
    for k, v in spec.env {
      env_desc = env_desc + " " + k + "=" + v
    }
    println("[supervise] plan \{spec.name}: \{spec.bin}\{env_desc}")
  }
}

///|
async fn main {
  let config = SupervisorConfig::from_env()
  print_plan(config)
  // SIGINT / SIGTERM → 取消主任务，随后进入优雅收尾
  @signal.set_global_cancellation_signals([
    @signal.SIGINT,
    @signal.SIGTERM,
  ])
  let result : Result[Unit, Error] = try {
    @async.with_task_group(async fn (group : @async.TaskGroup[Unit]) -> Unit {
      let sup = Supervisor::new(group, config)
      group.add_defer(async fn () nocancel {
        // 收尾阶段必须跑完（不受取消影响），否则子进程会变成孤儿。
        @async.protect_from_cancel(async fn () {
          sup.stop_all()
        })
      })
      sup.run()
    })
    Ok(())
  } catch {
    e => Err(e)
  }
  match result {
    Ok(_) => println("[supervise] shutdown complete")
    Err(_) => println("[supervise] shutdown complete (signal)")
  }
}
