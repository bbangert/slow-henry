# NIF Isolation Strategies for Unstable Rustler Libraries

## Executive Summary

This research explores how to isolate unstable Rustler NIFs (like `tree_sitter_language_pack`) that may crash the BEAM VM due to unsafe native code. The critical distinction is **panic vs. segfault**: Rustler can catch Rust panics and convert them to Erlang exceptions, but C-level segfaults and memory corruption bypass all protections. The tree-sitter C core has documented crash issues on malformed input (segfaults, assertion failures, memory corruption). This document reviews six isolation strategies with real tradeoffs.

---

## 1. Rustler Panic Behavior vs. Segfaults

### What Rustler Does (Panic Handling)

Rustler's core safety promise is: **"The code you write in a Rust NIF should never be able to crash the BEAM."**

**Implementation**: Rustler uses `catch_unwind` internally to catch Rust panics before they unwind into the Erlang C stack. When a Rust panic occurs:
- Rustler catches it via `catch_unwind`
- Converts it to an Erlang exception (`:error` tuple)
- Returns to Erlang instead of unwinding through C frames
- The exception propagates normally through Elixir/Erlang error handling

**This is recoverable**: The calling process can catch the error via try/rescue or pattern matching, and supervisors can restart the process.

### The Segfault Problem (Panic ≠ Segfault)

**Critical distinction**: Rust `panic!()` ≠ C segfault.

- **Rust panic**: Uses Rust's unwinding mechanism. Rustler's `catch_unwind` stops it at the FFI boundary. **Recoverable**.
- **C segfault** (memory-unsafe crash): Happens at the CPU/OS level (invalid memory access, null dereference, use-after-free in C code). **NOT caught by catch_unwind**. Kills the entire BEAM process immediately.

### Tree-Sitter C Core: Documented Crash Issues

Tree-sitter is written in C and has NO panic-safety guarantees. GitHub issues document real crashes on malformed input:

| Issue | Crash Type | Trigger | Impact |
|-------|-----------|---------|--------|
| [#175 tree-sitter-cpp](https://github.com/tree-sitter/tree-sitter-cpp/issues/175) | `munmap_chunk(): invalid pointer` | Parsing certain C++ files | Memory corruption crash |
| [#933 tree-sitter](https://github.com/tree-sitter/tree-sitter/issues/933) | Assertion failure `assert(symbol < self->token_count)` | Boundary violation in token parsing | Hard abort |
| [#64 tree-sitter-c](https://github.com/tree-sitter/tree-sitter-c/issues/64) | Segmentation fault | Parsing block comments `/* */` | Segfault |
| [#4277 tree-sitter](https://github.com/tree-sitter/tree-sitter/issues/4277) | Sort comparison panic | Malformed grammar | Abort in standard library |

**Implication**: A Rustler binding to tree-sitter can still crash the BEAM if the C core segfaults on bad input—catch_unwind only stops Rust panics, not C crashes.

---

## 2. Dirty Schedulers

### What It Does

The BEAM has a fixed number of scheduler threads (typically one per core). NIFs block schedulers, preventing other Elixir processes from running on that thread. **Dirty schedulers** are separate thread pools for long-running or blocking operations.

Mark a NIF with `#[nif(schedule = "DirtyCpu")]` or `#[nif(schedule = "DirtyIo")]` to run on dedicated threads instead of the main scheduler threads.

### Does It Protect Against Segfaults?

**No**. Dirty schedulers only isolate *scheduler blocking*, not crashes.

- ✓ Prevents one slow NIF from starving other processes on its scheduler
- ✗ If the NIF segfaults on a dirty scheduler thread, it still crashes the entire BEAM VM (the Erlang runtime process itself)

### Real-World Test

[GitHub gist by Dave Peticolas](https://gist.github.com/davisp/1e71ec7f2f7a70d1b79c) includes a test case for NIF segfault with dirty schedulers—confirming that **dirty schedulers do not prevent VM-wide segfaults**.

### Takeaway

Dirty schedulers solve latency/scheduling problems, not safety problems. They do not isolate against crashes.

---

## 3. Separate OTP Node / Worker Node Isolation

### Pattern

Run the parser on a separate BEAM node (separate OS process) connected via distribution (Erlang distribution protocol over TCP).

**Architecture**:
```
Main Node
  └─ GenServer -> calls :rpc.call(ParserNode, Module, func, [args])
  
Separate ParserNode
  └─ Parser GenServer (linked to Supervisor)
     └─ On crash: node dies, :rpc call fails, main node gets error
```

When the parser node crashes:
- The main node loses connection (timeout or explicit detection)
- A supervisor on the main node restarts the parser node
- Application continues, only parsing temporarily unavailable

### Libraries / Patterns

- **Pogo** ([szajbus.dev](https://szajbus.dev/elixir/2023/05/22/pogo-distributed-supervisor-for-elixir.html)): Distributed supervisor that schedules processes across nodes. Can supervise work "somewhere" in the cluster; if a node crashes, work migrates to a healthy node.
- **Direct :rpc.call**: Use Erlang's built-in `:rpc.call(Node, Module, Func, Args)` with timeouts
- **Supervised remote node**: Start a separate Elixir release running just the parser; supervisor restarts if it dies

### Pros
- True isolation: segfault kills only the parser node, not main application
- Restarts are automatic via standard OTP supervision
- No serialization overhead if using Erlang terms over distribution
- Natural for multi-node deployments

### Cons
- **Latency**: Distribution adds 1–5ms per call (network, serialization)
- **Complexity**: Managing separate node lifecycle (start, stop, health checks)
- **Erlang terms only**: Must serialize/deserialize data; binary data requires encoding (base64)
- **Network fragility**: Node split or connection loss is indistinguishable from crash

### Use Case
Good for **infrequent parsing** (one per request) or **large files** where latency is amortized. Poor for hot-path, microsecond-scale parsing.

---

## 4. External OS Process via Port / erlexec

### Pattern

Spawn a separate OS process (not an Erlang node) that runs the parser. Communicate via `Port.open/2` and stdin/stdout.

**Architecture**:
```
Elixir Process
  ├─ Port.open/2 -> spawns OS process (e.g., Rust CLI or sh wrapper)
  ├─ Port.command/2 -> sends JSON/binary to stdin
  └─ receive -> gets result from stdout, or :EXIT if process crashes
```

When the OS process crashes:
- The port closes (`:EXIT` message to owner process)
- Owner process detects it and restarts the port
- BEAM remains unaffected

### Examples

1. **Simple sh + Rust CLI**: Write a tiny Rust binary that reads file from stdin, parses, outputs JSON. Elixir spawns it per-request.
   ```bash
   Port.open({:spawn, "tree_sitter_parse"}, [:binary, :use_stdio])
   ```

2. **erlexec** ([saleyn/erlexec](https://github.com/saleyn/erlexec)): Erlang OTP library for managing OS processes with back-pressure, resource limits, and graceful shutdown.

3. **Exile** ([akashrajpurohit/exile](https://elixirforum.com/t/exile-nif-based-alternative-to-ports-for-running-external-programs-provides-back-pressure-using-non-blocking-io/31639)): NIF-based wrapper around ports with non-blocking I/O and back-pressure support (avoids the latency of pure Erlang ports).

### Pros
- **True isolation**: Segfault kills only the OS process, never the BEAM
- **Security**: Untrusted/unvetted code is completely isolated
- **Simplicity**: Restart logic is trivial (GenServer + spawn_link)
- **Standards-based**: Uses Erlang's native port mechanism
- **Fits supervision tree**: Port-owning GenServer can be restarted by a supervisor

### Cons
- **Latency**: Serialization (JSON/protobuf) + process spawn overhead (~1–50ms per call depending on spawn strategy)
- **Spawn cost**: Creating a new OS process per call is expensive; connection pooling helps but adds complexity
- **Serialization overhead**: Data must be encoded to text/binary for transmission
- **Resource usage**: Each process consumes OS memory (~10–50MB for a Rust binary)

### Real-World Example: AppSignal Segfault (Issue #113)

[AppSignal NIF segfault issue #113](https://github.com/appsignal/appsignal-elixir/issues/113) (2017): AppSignal's NIF segfaulted on the BEAM with no clear stack trace (NIFs hide the Erlang stack). The recommended resolution was:

> "Wouldn't it be safer if the interaction with the extension was made using a Port? Ports fit nicely in a supervision tree and in a case like this, it will not bring the entire VM down."

### Use Case
**Best for untested/unstable libraries**. Accept the latency cost to guarantee safety. Pool processes or use Exile for better performance.

---

## 5. Input Validation / Pre-flight Caps

### Approach

Reduce crash surface area by validating/capping input *before* passing to the NIF.

**Examples**:
- Max file size (e.g., 10MB limit)
- Byte sequence caps (e.g., max line length, reject if >100k lines)
- Encoding checks (UTF-8 validation, reject binary)
- Reject known-bad patterns (e.g., deeply nested structures)
- Async streaming (parse chunks instead of whole file)

### Pros
- **No overhead**: Validation is fast (pattern matching, size checks)
- **Complementary**: Can combine with any other strategy
- **Reduces actual crash likelihood**: Many crashes stem from edge-case inputs

### Cons
- **Not a safety guarantee**: Validation can have bugs or miss edge cases (tree-sitter has documented crashes on valid-looking input)
- **Only reduces odds**: Does not protect against all segfaults
- **Fragile**: Requires maintaining a blacklist/whitelist that tracks library bugs

### Example: File Size Cap

```elixir
def parse_file(path) do
  case File.stat(path) do
    {:ok, %{size: size}} when size > 10_000_000 ->
      {:error, :file_too_large}
    {:ok, _stat} ->
      # Safe to parse
      MyNifParser.parse(path)
    {:error, reason} ->
      {:error, reason}
  end
end
```

### Documented Issues Addressable by Validation

- tree-sitter munmap crash (#175): Occurs on certain C++ code patterns—cannot easily validate away without parsing the code (circular dependency)
- Assert failure (#933): Boundary violation—input validation could catch deeply nested structures or unusual token counts
- Sort panic (#4277): Malformed grammar—tree-sitter-generate input validation could catch before passing to sort

### Takeaway

Input validation is a **mitigation, not a solution**. It reduces surface area but does not guarantee safety against a fundamentally unsafe library. Use in combination with Ports or separate nodes.

---

## 6. Real-World Community Incidents

### AppSignal NIF Segfault (2017)

**Issue**: [appsignal/appsignal-elixir#113](https://github.com/appsignal/appsignal-elixir/issues/113)

**Symptom**: Segfault crash in `appsignal_extension.so` with no stack trace

**Why no stack trace?**: NIFs hide the Erlang stack; crashes appear as raw OS signals, not Elixir exceptions

**Resolution recommended**: Migrate to Ports to contain crashes. No documented fix of the underlying NIF crash.

**Lesson**: When a Rustler/NIF crash occurs, the fix is often architectural (use Ports), not code-level.

### tree-sitter Stability Reports

No documented Elixir-specific incidents of tree-sitter crashing BEAM, but:
- C library has multiple documented segfaults and assertion failures
- A Rustler binding to tree-sitter is vulnerable to these crashes
- Example: `ex_tree_sitter_highlight` (hex/crates.io) provides a Rustler binding—may inherit tree-sitter's crash issues

**Community guidance** (from search): "If the native library is not well-tested and stable, use a Port to isolate the risk."

### Absence of Documented Incidents

Notably, there are very few public reports of tree-sitter crashing BEAM in production. Possible reasons:
1. Most tree-sitter usage is not in Elixir (used in VS Code, GitHub, editors—all JavaScript/TypeScript)
2. Elixir adoption of tree-sitter is newer and smaller
3. Projects using tree-sitter may not report crashes publicly
4. Projects that encounter crashes may quietly switch to Ports (not documented)

---

## Summary of Strategies

| Strategy | Segfault Protection | Panic Protection | Latency | Complexity | Best For |
|----------|:--:|:--:|:--:|:--:|---|
| **Rustler catch_unwind** | ✗ No | ✓ Yes | Microseconds | Low | Fast, tested native code only |
| **Dirty schedulers** | ✗ No | ✓ Yes | Microseconds | Low | Blocking (not crashing) NIFs |
| **Separate node** | ✓ Yes | ✓ Yes | 1–5ms | Medium | Infrequent parsing, multi-node deployments |
| **Ports / OS process** | ✓ Yes | ✓ Yes | 1–50ms | Medium | Untested/unstable libraries, strict isolation |
| **Exile (NIF Port wrapper)** | ✓ Yes | ✓ Yes | 100–500µs | Medium | Ports with better latency |
| **Input validation** | ✗ Partial | ✓ Partial | Negligible | Low | Combine with other strategies |

---

## Recommendation for tree_sitter_language_pack

Given tree-sitter's documented crash issues and lack of panic-safety:

1. **For high-reliability systems**: Use **Ports** (or Exile) + input validation. Accept 1–50ms latency.
2. **For low-frequency parsing** (e.g., one parse per user request): **Ports** are ideal.
3. **For hot-path, high-frequency parsing** (thousands of parses/sec): **Separate node** with automatic restart, or accept the risk and **input validation only**.
4. **Never use bare Rustler binding** (no isolation) on user-supplied input without extreme confidence in tree-sitter stability.

---

## References

### Tier 1 (Authoritative)

- [Rustler GitHub](https://github.com/rusterlium/rustler) — Official Rustler library, panic handling documentation
- [Erlang Ports](https://www.erlang.org/doc/man/erlang.html#open_port-2) — Official Erlang port documentation
- [tree-sitter GitHub Issues](https://github.com/tree-sitter/tree-sitter/issues) — Documented crashes and assertion failures

### Tier 2 (First-party / High-quality blogs)

- [Allan MacGregor: Rust NIFs in Elixir](https://allanmacgregor.com/posts/using-elixir-nif-to-integrate-with-rust) — Comprehensive NIF safety guide
- [Theerlangelist: Outside Elixir (Ports)](https://www.theerlangelist.com/article/outside_elixir) — Ports vs NIFs comparison by Saša Jurić
- [Pogo Distributed Supervisor](https://szajbus.dev/elixir/2023/05/22/pogo-distributed-supervisor-for-elixir.html) — Distributed supervision pattern

### Tier 3 (Community / Real incidents)

- [AppSignal NIF Segfault #113](https://github.com/appsignal/appsignal-elixir/issues/113) — Real-world incident, port recommendation
- [ElixirForum: ex_tree_sitter_highlight](https://elixirforum.com/t/ex-tree-sitter-highlight-makeup-alternative-implemented-with-rustler-binding-to-tree-sitter/62426) — Community tree-sitter binding
- [Exile: NIF-based Port Alternative](https://elixirforum.com/t/exile-nif-based-alternative-to-ports-for-running-external-programs-provides-back-pressure-using-non-blocking-io/31639) — Hybrid approach for better port latency

---

## Technical Depth: Panic vs. Segfault

### Rust Panic Mechanism

When Rust code panics:
1. Panic hook fires (prints "thread panicked" message)
2. If unwinding is enabled (default): Stack unwinding begins
3. Drop handlers run as stack frames unwind
4. At the FFI boundary (Rustler's NIF), `catch_unwind` intercepts the unwinding
5. Panic is converted to an Erlang exception (`:error` or similar)
6. Erlang receives an exception, normal error handling applies

**Rustler's catch_unwind wrapper** (simplified):
```rust
// Inside Rustler macro
match std::panic::catch_unwind(|| {
    user_nif_function(args)
}) {
    Ok(result) => Ok(result),
    Err(_panic) => Err(error::Error::RustPanic(...))
}
```

### C Segfault Mechanism

When C code (tree-sitter) causes a segfault:
1. Dereferencing an invalid pointer (null, uninitialized, freed memory)
2. Writing outside allocated bounds
3. Double-free or corruption (e.g., `munmap_chunk()`)
4. CPU raises a hardware exception (SIGSEGV signal)
5. **No unwinding, no exception handling**: OS terminates the process immediately
6. Entire BEAM process dies (not just the calling Erlang process)

**Why catch_unwind doesn't help**: It only catches Rust panics (language-level exceptions), not OS-level signals.

---

## Version Notes

This research reflects the state of Rustler, BEAM, and tree-sitter as of July 2026. Key assumptions:
- Rustler >= 0.30 (catch_unwind behavior stable)
- Erlang/OTP >= 24 (dirty schedulers standard)
- tree-sitter >= 0.20 (issues #933, #175 still present in codebase)

Future tree-sitter releases may address documented crashes, reducing the risk of bare Rustler bindings.
