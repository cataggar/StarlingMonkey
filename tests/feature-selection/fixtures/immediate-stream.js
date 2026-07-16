const reader = new Blob(["immediate-stream-ok"]).stream().getReader();
let value = "";
while (true) {
  const chunk = await reader.read();
  if (chunk.done) break;
  value += new TextDecoder().decode(chunk.value);
}
if (value !== "immediate-stream-ok") {
  throw new Error(`unexpected immediate stream result: ${value}`);
}
