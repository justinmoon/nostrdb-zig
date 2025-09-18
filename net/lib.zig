const std = @import("std");

pub const Allocator = std.mem.Allocator;

const message = @import("message.zig");
const relay_client = @import("relay_client.zig");
const relay_pool = @import("relay_pool.zig");
const mock_relay = @import("mock_relay.zig");

pub const RelayMessage = message.RelayMessage;
pub const RelayEvent = message.Event;
pub const RelayEose = message.Eose;
pub const RelayNotice = message.Notice;
pub const RelayOk = message.Ok;
pub const RelayUnknown = message.Unknown;
pub const RelayMessageParseError = message.ParseError;
pub const RelayMessageParser = message.Parser;

pub const RelayClient = relay_client.RelayClient;
pub const RelayClientState = relay_client.RelayClientState;
pub const RelayClientOptions = relay_client.Options;
pub const RelayClientConnectError = relay_client.ConnectError;
pub const RelayClientSendError = relay_client.SendError;

pub const RelayPool = relay_pool.RelayPool;
pub const RelayPoolConfig = relay_pool.Config;
pub const RelayPoolError = relay_pool.PoolError;

pub const MockRelayServer = mock_relay.MockRelayServer;
pub const MockRelayServerOptions = mock_relay.Options;
pub const MockRelayResponse = mock_relay.Response;
pub const MockRelayResponseBatch = mock_relay.ResponseBatch;
pub const MockRelayRequestLog = mock_relay.RequestLog;
pub const MockRelayServerError = mock_relay.MockError;

pub fn version() []const u8 {
    return "phase2-scaffold";
}
