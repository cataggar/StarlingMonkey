# Preview1 adapters

Each supported host API carries an adapter with the same WASI interface
version as its generated bindings and WIT closure:

| Host API | Adapter source |
| --- | --- |
| `wasi-0.2.0` | Wasmtime v24 reactor adapter |
| `wasi-0.2.2` | Wasmtime v27 reactor adapter |
| `wasi-0.2.3` | Wasmtime v29 reactor adapter |
| `wasi-0.2.10` | Existing generated 0.2.10 reactor adapter |

The release adapter is also used for Debug builds where an upstream
version-matched debug artifact is not published. `wasm-tools component wit`
must report the selected host API version for every installed adapter.
