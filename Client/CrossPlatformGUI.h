#pragma once

#include "imgui/imgui.h"
#include "Constants.h"
#include "IBluetoothConnector.h"
#include "BluetoothWrapper.h"
#include "CommandSerializer.h"
#include "Exceptions.h"
#include "TimedMessageQueue.h"
#include "SingleInstanceFuture.h"
#include "CascadiaCodeFont.h"
#include "Headphones.h"

#include <future>
#include <array>
#include <map>
#include <string>

constexpr auto GUI_MAX_MESSAGES = 5;
constexpr auto GUI_HEIGHT = 660;
constexpr auto GUI_WIDTH = 460;
constexpr auto FPS = 60;
constexpr auto MS_PER_FRAME = 1000 / FPS;
constexpr auto FONT_SIZE = 16.0f;
const auto WINDOW_COLOR = ImVec4(0.09f, 0.09f, 0.11f, 1.00f);

// Physical-button changes (ASM) are polled roughly every two seconds so the app stays in sync.
constexpr auto DYNAMIC_POLL_FRAMES = FPS * 2;

class CrossPlatformGUI
{
public:
	CrossPlatformGUI(BluetoothWrapper bt);

	//Run the GUI code once. This function should be called from a loop from one of the GUI impls (Windows, OSX, Linux...)
	//O: true if the user wants to close the window
	bool performGUIPass();
private:
	void _applyTheme();

	void _drawErrors();
	void _drawDeviceDiscovery();
	void _drawStatusHeader();
	void _drawASMControls();
	void _drawEqualizer();
	void _drawDsee();
	void _drawOptionalFeatures();
	void _drawSurroundControls();

	// Connection lifecycle: read device state after connect, then poll button-changeable state.
	void _pumpConnectionState();
	void _syncUIFromHeadphones();
	void _sendPendingASMChanges();
	// Fire an immediate-setter feature command (EQ/DSEE/auto-power-off/…) on the worker future if it's idle.
	template <typename F> void _sendFeatureCommand(F&& fn);

	bool _beginCard(const char* id);
	void _endCard();
	void _cardTitle(const char* title);

	// Device hero image (loaded from resources/devices/<slug>.png, uploaded via ImGui's 1.92 texture API).
	struct DeviceTexture { ImTextureRef ref; int w = 0; int h = 0; bool ok = false; };
	const DeviceTexture& _deviceTexture(const std::string& name);
	std::string _resourceBase();

	bool _isV2() { return _bt.getProtocolVersion() == SonyProtocolVersion::V2; }

	BluetoothDevice _connectedDevice;
	BluetoothWrapper _bt;
	SingleInstanceFuture<std::vector<BluetoothDevice>> _connectedDevicesFuture;
	SingleInstanceFuture<void> _sendCommandFuture;
	SingleInstanceFuture<void> _featureCommandFuture;
	SingleInstanceFuture<void> _refreshFuture;
	SingleInstanceFuture<void> _probeFuture;
	SingleInstanceFuture<void> _pollFuture;
	SingleInstanceFuture<void> _connectFuture;
	TimedMessageQueue _mq;
	Headphones _headphones;

	bool _initialized = false;
	bool _synced = false;
	bool _probed = false;
	int _pollCounter = 0;

	// UI state, synced from the device once after connect; user edits are pushed back to the headphones.
	bool _uiAsmOn = false;
	int _uiAsmMode = 0;          // 0 = Off, 1 = Noise Cancelling, 2 = Ambient Sound
	int _uiAsmLevel = 0;
	bool _uiFocusOnVoice = false;
	int _uiEqPreset = 0;
	std::array<int, 5> _uiEqBands = { 0, 0, 0, 0, 0 };
	int _uiClearBass = 0;
	bool _uiDsee = false;
	int _uiAutoPowerOff = 0;
	bool _uiSpeakToChat = false;
	bool _uiAdaptiveVolume = false;
	int _uiSoundPosition = 0;
	int _uiVptType = 0;

	std::map<std::string, DeviceTexture> _deviceTextures;
};

template <typename F>
void CrossPlatformGUI::_sendFeatureCommand(F&& fn)
{
	if (_featureCommandFuture.valid())
		return;
	_featureCommandFuture.setFromAsync(std::forward<F>(fn));
}
