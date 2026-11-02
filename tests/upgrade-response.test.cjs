const { describe, test } = require("node:test");
const assert = require("node:assert/strict");
const net = require("node:net");

const { writeUpgradeFailureResponse } = require("../upgrade-response.cjs");

// CI-HERMES-1: answering a refused upgrade wrote to a client that had already gone.
// The resulting EPIPE was an 'error' event with no listener, which crashed the process.

function listen(onConnection) {
  return new Promise((resolve, reject) => {
    const server = net.createServer(onConnection);
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe("writeUpgradeFailureResponse", () => {
  test("answers a client that is still connected", async () => {
    const server = await listen((socket) => {
      writeUpgradeFailureResponse(socket, 502, "upstream down");
    });
    let received = "";
    const client = net.connect(server.address().port, "127.0.0.1");
    client.setEncoding("utf8");
    client.on("data", (chunk) => {
      received += chunk;
    });
    await new Promise((resolve) => client.on("close", resolve));
    server.close();

    assert.match(received, /^HTTP\/1\.1 502 Bad Gateway\r\n/);
    assert.ok(received.includes("Content-Length: 14\r\n"));
    assert.ok(received.endsWith("\r\n\r\nupstream down\n"));
  });

  test("leaves a client that already closed alone", async () => {
    const errors = [];
    const handled = deferred();
    const server = await listen((socket) => {
      socket.on("error", (error) => errors.push(error));
      socket.on("close", () => {
        writeUpgradeFailureResponse(socket, 502, "too late");
        setImmediate(() => handled.resolve(socket.destroyed));
      });
    });
    const client = net.connect(server.address().port, "127.0.0.1", () => client.destroy());
    client.on("error", () => {});
    const destroyed = await handled.promise;
    server.close();

    assert.equal(destroyed, true);
    assert.deepEqual(errors, []);
  });

  test("absorbs a write error on a socket that is still open", async () => {
    const outcome = deferred();
    const server = await listen((socket) => {
      try {
        writeUpgradeFailureResponse(socket, 502, "x");
        // A write that fails mid-response surfaces as an 'error' event. With no
        // listener on the socket, emit() throws here and the test fails.
        socket.emit("error", Object.assign(new Error("write EPIPE"), { code: "EPIPE" }));
        outcome.resolve(socket.destroyed);
      } catch (error) {
        outcome.reject(error);
      }
    });
    const client = net.connect(server.address().port, "127.0.0.1");
    client.on("error", () => {});
    client.resume();
    try {
      assert.equal(await outcome.promise, true);
    } finally {
      client.destroy();
      server.close();
    }
  });
});
