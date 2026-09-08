package main

/*
#include <stdint.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	serverMu sync.Mutex
	server   *core.Instance
)

func cError(err error) *C.char {
	if err == nil {
		return C.CString("")
	}
	return C.CString(err.Error())
}

func cString(s string) *C.char {
	return C.CString(s)
}

// XraySetTunFd 必须在 XrayStart 之前调用。
// C 侧 setenv 在本平台对 Go runtime 的 os.LookupEnv 不可见，
// 因此必须走 Go 的 os.Setenv，AndroidTun 才会读到正确 fd。
//
//export XraySetTunFd
func XraySetTunFd(fd C.int) {
	s := strconv.Itoa(int(fd))
	_ = os.Setenv("xray.tun.fd", s)
	_ = os.Setenv("XRAY_TUN_FD", s)
}

// XraySetAssetPath 设置 geoip.dat / geosite.dat 所在目录。
//
//export XraySetAssetPath
func XraySetAssetPath(path *C.char) {
	dir := C.GoString(path)
	if dir != "" {
		_ = os.Setenv("xray.location.asset", dir)
	}
}

//export XrayStart
func XrayStart(configJson *C.char) *C.char {
	serverMu.Lock()
	defer serverMu.Unlock()

	if server != nil {
		return cError(fmt.Errorf("xray already running"))
	}

	cfg := C.GoString(configJson)
	if strings.TrimSpace(cfg) == "" {
		return cError(fmt.Errorf("empty config"))
	}

	config, err := core.LoadConfig("json", strings.NewReader(cfg))
	if err != nil {
		return cError(fmt.Errorf("load config: %w", err))
	}

	inst, err := core.New(config)
	if err != nil {
		return cError(fmt.Errorf("new instance: %w", err))
	}
	if err = inst.Start(); err != nil {
		_ = inst.Close()
		return cError(fmt.Errorf("start: %w", err))
	}

	server = inst
	return cError(nil)
}

//export XrayStop
func XrayStop() {
	serverMu.Lock()
	defer serverMu.Unlock()
	if server != nil {
		_ = server.Close()
		server = nil
	}
	_ = os.Unsetenv("xray.tun.fd")
	_ = os.Unsetenv("XRAY_TUN_FD")
}

//export XrayIsRunning
func XrayIsRunning() C.int {
	serverMu.Lock()
	defer serverMu.Unlock()
	if server != nil && server.IsRunning() {
		return 1
	}
	return 0
}

type trafficStats struct {
	Uplink   int64 `json:"uplink"`
	Downlink int64 `json:"downlink"`
}

//export XrayQueryStats
func XrayQueryStats(tag *C.char) *C.char {
	serverMu.Lock()
	defer serverMu.Unlock()

	out := trafficStats{}
	if server == nil {
		b, _ := json.Marshal(out)
		return cString(string(b))
	}

	feat := server.GetFeature(stats.ManagerType())
	if feat == nil {
		b, _ := json.Marshal(out)
		return cString(string(b))
	}
	sm, ok := feat.(stats.Manager)
	if !ok || sm == nil {
		b, _ := json.Marshal(out)
		return cString(string(b))
	}

	name := C.GoString(tag)
	if name == "" {
		name = "proxy"
	}
	if c := sm.GetCounter(fmt.Sprintf("outbound>>>%s>>>traffic>>>uplink", name)); c != nil {
		out.Uplink = c.Value()
	}
	if c := sm.GetCounter(fmt.Sprintf("outbound>>>%s>>>traffic>>>downlink", name)); c != nil {
		out.Downlink = c.Value()
	}
	b, _ := json.Marshal(out)
	return cString(string(b))
}

func main() {}
