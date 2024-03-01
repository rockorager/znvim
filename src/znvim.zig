//! This file is used to expose the api to the outside world and briefly package rpc
const std = @import("std");
const builtin = @import("builtin");
const msgpack = @import("msgpack");

const rpc = @import("rpc.zig");
const config = @import("config.zig");
const named_pipe = @import("named_pipe.zig");

/// api define
pub const api_defs = @import("api_defs.zig");

const net = std.net;
const Type = std.builtin.Type;
const Allocator = std.mem.Allocator;
const MetaData = api_defs.nvim_get_api_info.MetaData;

const EnumLiteral = @TypeOf(.EnumLiteral);

const comptimePrint = std.fmt.comptimePrint;

/// wrap str
pub const wrapStr = msgpack.wrapStr;
/// client enum
pub const ClientEnum = rpc.ClientEnum;
/// connect named pipe, only for windows
pub const connectNamedPipe = named_pipe.connectNamedPipe;

/// this is api infos
const api_info = @typeInfo(api_defs).Struct;

const CallErrorSet = error{
    APIDeprecated,
    NotFindApi,
};

/// Error types for neovim result
pub const error_types = config.error_types;

/// get all available api enum
pub const api_enum: type = blk: {
    var fields: [api_info.decls.len]Type.EnumField = undefined;

    for (api_info.decls, 0..) |decl, i| {
        fields[i].name = decl.name;
        fields[i].value = i;
    }

    break :blk @Type(Type{
        .Enum = .{
            .is_exhaustive = false,
            .decls = &.{},
            .tag_type = u16,
            .fields = &fields,
        },
    });
};

/// get api type define
inline fn get_api_type_def(comptime api: api_enum) type {
    const api_name = @tagName(api);
    for (api_info.decls) |decl| {
        if (decl.name.len == api_name.len and std.mem.eql(u8, decl.name, api_name)) {
            return @field(api_defs, decl.name);
        }
    }
    const err_msg = comptimePrint("not found the api ({s})", .{api_name});
    @compileError(err_msg);
}

/// used to get api parameters
fn get_api_parameters(comptime api: api_enum) type {
    const api_name = @tagName(api);
    const api_def = get_api_type_def(api);
    if (comptime !@hasDecl(api_def, "parameters")) {
        @compileError(comptimePrint(
            "not found {} in api ({})",
            .{ "parameters", api_name },
        ));
    }
    const api_params_def: type = @field(api_def, "parameters");
    const api_params_def_type_info = @typeInfo(api_params_def);
    if (api_params_def_type_info == .Struct) {
        if (api_params_def_type_info.Struct.is_tuple) {
            return api_params_def;
        } else if (api_params_def_type_info.Struct.fields.len == 0) {
            return @Type(.{
                .Struct = .{
                    .layout = .Auto,
                    .fields = &.{},
                    .decls = &.{},
                    .is_tuple = true,
                },
            });
        } else {
            const err_msg = comptimePrint(
                "api ({})'s parameters ({}) is invalid, it must be tuple",
                .{ api_name, api_params_def },
            );
            @compileError(err_msg);
        }
    } else {
        @compileError(comptimePrint(
            "api ({s})'s parameters should be tuple",
            .{api_name},
        ));
    }
}

/// used to get api return_type
fn get_api_return_type(comptime api: api_enum) type {
    const api_name = @tagName(api);
    const api_def = get_api_type_def(api);
    if (comptime !@hasDecl(api_def, "return_type")) {
        @compileError(comptimePrint(
            "not found {} in api ({s})",
            .{ "return_type", api_name },
        ));
    }
    const api_return_type_def: type = @field(api_def, "return_type");
    if (api_return_type_def == config.NoAutoCall) {
        @compileError(comptimePrint(
            "api ({s}) can not be used in call, please use call_with_reader",
            .{api_name},
        ));
    }
    return api_return_type_def;
}

/// default client type, buffer size is 20480 bytes
pub fn DefaultClientType(comptime pack_type: type, comptime client_tag: ClientEnum) type {
    return Client(pack_type, client_tag, 20480);
}

/// create a client type
/// pack_type is the struct which contain methods
/// client_tag is the client enum
/// buffer_size is the size of buffer
pub fn Client(
    comptime pack_type: type,
    comptime client_tag: ClientEnum,
    comptime buffer_size: usize,
) type {
    const RpcClientType = rpc.CreateClient(pack_type, buffer_size, client_tag);
    const Writer = RpcClientType.Writer;
    const Reader = RpcClientType.Reader;
    return struct {
        /// rpc client instance
        rpc_client: RpcClientType,
        /// channel id, when connect to neovim, it will assign client an id
        channel_id: u16,
        /// the api infos
        metadata: MetaData,
        allocator: Allocator,

        const Self = @This();

        /// the client payloadType
        /// only can be `std.net.Stream` or std.fs.File
        pub const payloadType = RpcClientType.payloadType;

        /// init the client
        /// After use, need to call deinit
        pub fn init(
            payload_writer: payloadType,
            payload_reader: payloadType,
            allocator: Allocator,
            if_log: bool,
        ) !Self {
            var self: Self = undefined;

            const rpc_client = try RpcClientType.init(
                payload_writer,
                payload_reader,
                allocator,
                if_log,
            );
            errdefer rpc_client.deinit();
            self.rpc_client = rpc_client;
            self.allocator = allocator;

            const result = try self.call(.nvim_get_api_info, .{}, allocator);
            self.channel_id = result[0];
            self.metadata = result[1];

            return self;
        }

        /// cleanup the environment
        pub fn deinit(self: Self) void {
            self.rpc_client.deinit();
            self.destory_metadata();
        }

        /// detect the method whether exist
        /// this will use neovim's api info(MetaData)
        /// Only useful under Debug
        fn method_detect(self: Self, comptime method: anytype) !void {
            const m_type = @TypeOf(method);
            const m_type_info = @typeInfo(m_type);
            if (m_type_info != .Enum and m_type_info != .EnumLiteral) {
                const err_msg = comptimePrint("sorry, method ({}) must be enum or enumliteral", .{m_type});
                @compileError(err_msg);
            }

            const method_name = @tagName(method);
            // This will verify whether the method is available
            // in the current version in debug mode
            if (comptime (builtin.mode == .Debug and
                !std.mem.eql(u8, method_name, "nvim_get_api_info")))
            {
                var if_find = false;
                for (self.metadata.functions) |func| {
                    const func_name = func.name.value();
                    if (method_name.len != func_name.len or
                        !std.mem.eql(u8, method_name, func_name))
                        continue;

                    if_find = true;
                    if (func.deprecated_since) |deprecated_since| {
                        if (deprecated_since >= self.metadata.version.api_level) {
                            return CallErrorSet.APIDeprecated;
                        }
                    }
                    break;
                }

                if (!if_find) {
                    return CallErrorSet.NotFindApi;
                }
            }
        }

        /// call method
        pub fn call(
            self: Self,
            comptime method: api_enum,
            params: get_api_parameters(method),
            allocator: Allocator,
        ) !get_api_return_type(method) {
            const method_name = @tagName(method);
            try self.method_detect(method);
            return self.rpc_client.call(
                method_name,
                params,
                error_types,
                get_api_return_type(method),
                allocator,
            );
        }

        /// call method, will return a reader, you can use the reader to read response
        pub fn call_with_reader(
            self: Self,
            comptime method: api_enum,
            params: get_api_parameters(method),
            allocator: Allocator,
        ) !Reader {
            const method_name = @tagName(method);
            try self.method_detect(method);
            return self.rpc_client.call_with_reader(
                method_name,
                params,
                error_types,
                allocator,
            );
        }

        /// call method, return a writer to write params
        pub fn call_with_writer(self: Self, comptime method: EnumLiteral) !Writer {
            const method_name = @tagName(method);
            try self.method_detect(method);
            return self.rpc_client.call_with_writer(method_name);
        }

        /// get result through writer
        /// NOTE: the result type check will not be checked for the method
        pub fn get_result_with_writer(
            self: Self,
            comptime resultType: type,
            writer: Writer,
            allocator: Allocator,
        ) !resultType {
            return self.rpc_client.get_result_with_writer(
                writer,
                error_types,
                resultType,
                allocator,
            );
        }

        /// get reader through writer,  you can use the reader to read response
        pub fn get_reader_with_writer(
            self: Self,
            writer: Writer,
            allocator: Allocator,
        ) !Reader {
            return self.rpc_client.get_reader_with_writer(writer, error_types, allocator);
        }

        /// event loop
        /// please use for wrap this
        pub fn loop(self: Self, allocator: Allocator) !void {
            try self.rpc_client.loop(allocator);
        }

        /// destory the metadata
        fn destory_metadata(self: Self) void {
            const allocator = self.allocator;
            const metadata = self.metadata;

            // free version
            const version = metadata.version;
            defer allocator.free(version.build.value());

            // free functions
            const functions = metadata.functions;
            defer allocator.free(functions);
            for (functions) |function| {
                allocator.free(function.return_type.value());
                defer allocator.free(function.parameters);
                for (function.parameters) |parameter| {
                    for (parameter) |val| {
                        allocator.free(val.value());
                    }
                }
                allocator.free(function.name.value());
            }

            // free ui_events
            const ui_events = metadata.ui_events;
            defer allocator.free(ui_events);
            for (ui_events) |ui_event| {
                allocator.free(ui_event.name.value());
                defer allocator.free(ui_event.parameters);
                for (ui_event.parameters) |parameter| {
                    for (parameter) |val| {
                        allocator.free(val.value());
                    }
                }
            }

            // free ui_options
            const ui_options = metadata.ui_options;
            defer allocator.free(ui_options);
            for (ui_options) |val| {
                allocator.free(val.value());
            }

            // free types
            const types = metadata.types;
            allocator.free(types.Buffer.prefix.value());
            allocator.free(types.Window.prefix.value());
            allocator.free(types.Tabpage.prefix.value());
        }
    };
}
