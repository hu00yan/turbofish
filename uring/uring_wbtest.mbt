// uring 白盒测试（仅 native/llvm）：真实文件、真实线程/内核路径。
//
// 覆盖：原子写 + 整读、范围读（正常/越界）、16 路并发批量读的字节一致性、
// 不存在文件返回 None、close 幂等。
// 临时文件放 /tmp 并用 now() 保证跨运行唯一，测试结束用 engine.remove_file 清理。

///|
fn tf_test_path(tag : String) -> String {
  "/tmp/tf_uring_w1_\{tag}_\{@async.now()}.bin"
}

///|
fn tf_test_payload(n : Int) -> Bytes {
  let arr : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  for i in 0..<n {
    arr[i] = ((i * 31 + 7) & 0xFF).to_byte()
  }
  Bytes::from_array(arr)
}

///|
async test "uring: atomic write then whole-file read" {
  let engine = UringEngine::new(queue_depth=16)
  defer engine.close()
  assert_true(
    engine.backend_kind() == "linux_io_uring" ||
    engine.backend_kind() == "posix_pread_pool",
  )
  let path = tf_test_path("rw")
  let data = tf_test_payload(4096)
  engine.write_file_atomic(path, data, sync=true)
  assert_eq(engine.file_size(path), Some(4096L))
  match engine.read_file(path) {
    Some(got) => assert_eq(got, data)
    None => fail("read_file returned None for an existing file")
  }
  // 覆盖写：rename 语义下一次读必须看到全新内容
  let data2 = tf_test_payload(1234)
  engine.write_file_atomic(path, data2)
  match engine.read_file(path) {
    Some(got) => assert_eq(got, data2)
    None => fail("read_file returned None after overwrite")
  }
  // 空文件
  let empty_path = tf_test_path("empty")
  engine.write_file_atomic(empty_path, Bytes::make(0, b'\x00'))
  match engine.read_file(empty_path) {
    Some(got) => assert_eq(got.length(), 0)
    None => fail("read_file returned None for an empty file")
  }
  engine.remove_file(empty_path)
  engine.remove_file(path)
}

///|
async test "uring: range read (in-range and past EOF)" {
  let engine = UringEngine::new()
  defer engine.close()
  let path = tf_test_path("range")
  let data = tf_test_payload(1024)
  engine.write_file_atomic(path, data, sync=true)
  // 正常范围
  match engine.read_range(path, 100, 64) {
    Some(got) => assert_eq(got, data[100:164].to_owned())
    None => fail("in-range read failed")
  }
  // 跨 EOF：只返回实际存在的字节
  match engine.read_range(path, 1000, 100) {
    Some(got) => assert_eq(got, data[1000:1024].to_owned())
    None => fail("partially-overlapping read failed")
  }
  // 完全越界：不伪造数据，返回空
  match engine.read_range(path, 4096, 32) {
    Some(got) => assert_eq(got.length(), 0)
    None => fail("past-EOF read failed")
  }
  // 整段覆盖式读取与整读一致
  match engine.read_range(path, 0, 1024) {
    Some(got) => assert_eq(got, data)
    None => fail("full range read failed")
  }
  engine.remove_file(path)
}

///|
async test "uring: missing file returns None" {
  let engine = UringEngine::new()
  defer engine.close()
  let missing = "/tmp/tf_uring_w1_definitely_missing_\{@async.now()}.bin"
  assert_true(engine.read_file(missing) is None)
  assert_true(engine.read_range(missing, 0, 16) is None)
  assert_eq(engine.file_size(missing), None)
}

///|
async test "uring: 16 concurrent batched range reads agree byte-for-byte" {
  let engine = UringEngine::new(queue_depth=32)
  defer engine.close()
  // 8 个文件，长度各不相同，内容可校验
  let n_files = 8
  let files : Array[String] = []
  let payloads : Array[Bytes] = []
  for i in 0..<n_files {
    let path = tf_test_path("batch\{i}")
    let payload = tf_test_payload(512 + i * 97)
    engine.write_file_atomic(path, payload, sync=true)
    files.push(path)
    payloads.push(payload)
  }
  // 每个批次都读全部 8 个文件的 [0, len) 区间
  let reqs : Array[(String, Int, Int)] = []
  for i in 0..<n_files {
    reqs.push((files[i], 0, payloads[i].length()))
  }
  let errors : Array[String] = []
  // 16 路并发：每个任务跑一次完整批量读，逐字节比对
  @async.with_task_group(fn(group) {
    for _ in 0..<16 {
      group.spawn_bg(async fn() {
        let outs = engine.read_ranges_batch(reqs)
        if outs.length() != n_files {
          errors.push("batch length mismatch: \{outs.length()}")
          return
        }
        for i in 0..<n_files {
          match outs[i] {
            Some(got) =>
              if got != payloads[i] {
                errors.push(
                  "batch byte mismatch at \{i}: got \{got.length()} want \{payloads[i].length()}",
                )
              }
            None => errors.push("batch read returned None at \{i}")
          }
        }
      })
    }
  })
  assert_eq(errors.length(), 0)
  // 单批次里混入一个不存在的文件：只影响它自己的位置
  let mixed : Array[(String, Int, Int)] = [
    (files[0], 0, payloads[0].length()),
    ("/tmp/tf_uring_w1_nope_\{@async.now()}.bin", 0, 8),
    (files[1], 16, 32),
  ]
  let mixed_out = engine.read_ranges_batch(mixed)
  assert_eq(mixed_out.length(), 3)
  match mixed_out[0] {
    Some(got) => assert_eq(got, payloads[0])
    None => fail("mixed batch: valid read 0 failed")
  }
  assert_true(mixed_out[1] is None)
  match mixed_out[2] {
    Some(got) => assert_eq(got, payloads[1][16:48].to_owned())
    None => fail("mixed batch: valid read 2 failed")
  }
  for f in files {
    engine.remove_file(f)
  }
}

///|
async test "uring: close is idempotent and engine stays consistent" {
  let engine = UringEngine::new(queue_depth=8)
  let path = tf_test_path("close")
  engine.write_file_atomic(path, b"bye", sync=true)
  assert_eq(engine.queue_depth(), 8)
  assert_eq(engine.backend_kind(), engine.backend_kind())
  engine.close()
  engine.close()
  engine.close()
  assert_true(engine.backend_kind() != "")
  // 清理：引擎已关，用独立引擎删文件
  let cleaner = UringEngine::new()
  cleaner.remove_file(path)
  cleaner.close()
}

