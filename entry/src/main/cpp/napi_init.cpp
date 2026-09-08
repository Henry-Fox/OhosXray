#include "napi/native_api.h"
#include "xray_bridge.h"
#include <string>

namespace {

std::string GetStringArg(napi_env env, napi_value value) {
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    std::string result(len + 1, '\0');
    napi_get_value_string_utf8(env, value, &result[0], len + 1, &len);
    result.resize(len);
    return result;
}

napi_value Start(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string configJson = GetStringArg(env, args[0]);
    int32_t tunFd = 0;
    napi_get_value_int32(env, args[1], &tunFd);

    std::string err = XrayBridgeStart(configJson, tunFd);

    napi_value result;
    napi_create_string_utf8(env, err.c_str(), err.size(), &result);
    return result;
}

napi_value Stop(napi_env env, napi_callback_info info) {
    XrayBridgeStop();
    return nullptr;
}

napi_value IsRunning(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, XrayBridgeIsRunning(), &result);
    return result;
}

napi_value QueryStats(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string tag = argc > 0 ? GetStringArg(env, args[0]) : std::string("proxy");
    std::string statsJson = XrayBridgeQueryStats(tag);

    napi_value result;
    napi_create_string_utf8(env, statsJson.c_str(), statsJson.size(), &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"queryStats", nullptr, QueryStats, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

}  // namespace

extern "C" __attribute__((constructor)) void RegisterXrayBridgeModule(void) {
    static napi_module xraybridgeModule = {
        .nm_version = 1,
        .nm_flags = 0,
        .nm_filename = nullptr,
        .nm_register_func = Init,
        .nm_modname = "xraybridge",
        .nm_priv = nullptr,
        .reserved = {0},
    };
    napi_module_register(&xraybridgeModule);
}
