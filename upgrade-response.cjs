// Answers a WebSocket upgrade the Hub refused with a plain-text HTTP error. It lives
// outside server.cjs so tests/upgrade-response.test.cjs can load it without starting
// the server. The Dockerfile copies it next to server.cjs.
//
// The client can be gone by the time we answer: it closed the socket, or the proxy
// already failed. Writing to such a socket raises EPIPE as an 'error' event, and with
// no listener that event takes the whole process down (CI-HERMES-1). So skip the write
// once the socket is no longer writable, and absorb an error that arrives later.
function writeUpgradeFailureResponse(socket, statusCode, message) {
  if (!socket.writable) {
    socket.destroy();
    return;
  }
  socket.on("error", () => {
    socket.destroy();
  });
  const status = Number(statusCode) || 502;
  const text = String(message || "WebSocket upgrade failed.");
  const body = `${text}\n`;
  socket.write(`HTTP/1.1 ${status} Bad Gateway\r\n`);
  socket.write("Content-Type: text/plain; charset=utf-8\r\n");
  socket.write(`Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n`);
  socket.write("Connection: close\r\n");
  socket.write("Cache-Control: no-store\r\n");
  socket.write("\r\n");
  socket.end(body);
}

module.exports = { writeUpgradeFailureResponse };
