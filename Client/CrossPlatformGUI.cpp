#include "CrossPlatformGUI.h"

#include <string>
#include <vector>

bool CrossPlatformGUI::performGUIPass()
{
	ImGui::NewFrame();

	bool open = true;
	ImGuiIO& io = ImGui::GetIO();

	ImGui::SetNextWindowPos({ 0, 0 });
	ImGui::SetNextWindowSize(io.DisplaySize);
	ImGui::Begin("SonyBridge", &open,
		ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove |
		ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoBringToFrontOnFocus);

	ImGui::TextDisabled("Not affiliated with Sony. Use at your own risk.");
	ImGui::Spacing();

	this->_drawErrors();
	this->_drawDeviceDiscovery();

	if (this->_bt.isConnected())
	{
		this->_pumpConnectionState();

		if (this->_synced)
		{
			this->_drawStatusHeader();
			this->_drawASMControls();
			if (this->_isV2())
			{
				this->_drawEqualizer();
				this->_drawDsee();
			}
			this->_drawOptionalFeatures();
			if (!this->_isV2())
				this->_drawSurroundControls();

			this->_sendPendingASMChanges();
		}
		else
		{
			ImGui::Spacing();
			ImGui::TextDisabled("Reading device settings %c", "|/-\\"[(int)(ImGui::GetTime() / 0.1f) & 3]);
		}
	}
	else
	{
		this->_synced = false;
		this->_initialized = false;
		this->_pollCounter = 0;
	}

	ImGui::End();
	ImGui::Render();

	return open;
}

void CrossPlatformGUI::_drawErrors()
{
	if (this->_mq.begin() == this->_mq.end())
		return;

	for (auto&& message : this->_mq)
		ImGui::TextColored(ImVec4(0.95f, 0.45f, 0.45f, 1.0f), "%s", message.message.c_str());
	ImGui::Spacing();
}

void CrossPlatformGUI::_drawDeviceDiscovery()
{
	static std::vector<BluetoothDevice> connectedDevices;
	static int selectedDevice = -1;

	if (!this->_beginCard("##discovery")) { this->_endCard(); return; }

	if (this->_bt.isConnected())
	{
		ImGui::Text("Connected to %s", this->_connectedDevice.name.c_str());
		ImGui::Spacing();
		if (ImGui::Button("Disconnect"))
		{
			selectedDevice = -1;
			this->_bt.disconnect();
		}
		this->_endCard();
		return;
	}

	this->_cardTitle("Select a device");

	int temp = 0;
	for (const auto& device : connectedDevices)
	{
		std::string label = (device.name.empty() ? "Unknown Device" : device.name) + "##" + device.mac;
		ImGui::RadioButton(label.c_str(), &selectedDevice, temp++);
	}

	ImGui::Spacing();

	if (this->_connectFuture.valid())
	{
		if (this->_connectFuture.ready())
		{
			try
			{
				this->_connectFuture.get();
			}
			catch (const RecoverableException& exc)
			{
				if (exc.shouldDisconnect)
					this->_bt.disconnect();
				this->_mq.addMessage(exc.what());
			}
		}
		else
		{
			ImGui::Text("Connecting %c", "|/-\\"[(int)(ImGui::GetTime() / 0.05f) & 3]);
		}
	}
	else if (ImGui::Button("Connect"))
	{
		if (selectedDevice != -1)
		{
			this->_connectedDevice = connectedDevices[selectedDevice];
			this->_connectFuture.setFromAsync([this]() { this->_bt.connect(this->_connectedDevice.mac); });
		}
	}

	ImGui::SameLine();

	if (this->_connectedDevicesFuture.valid())
	{
		if (this->_connectedDevicesFuture.ready())
		{
			try
			{
				connectedDevices = this->_connectedDevicesFuture.get();
			}
			catch (const RecoverableException& exc)
			{
				if (exc.shouldDisconnect)
					this->_bt.disconnect();
				this->_mq.addMessage(exc.what());
			}
		}
		else
		{
			ImGui::Text("Discovering %c", "|/-\\"[(int)(ImGui::GetTime() / 0.05f) & 3]);
		}
	}
	else if (ImGui::Button("Refresh devices"))
	{
		selectedDevice = -1;
		this->_connectedDevicesFuture.setFromAsync([this]() { return this->_bt.getConnectedDevices(); });
	}

	this->_endCard();
}

void CrossPlatformGUI::_pumpConnectionState()
{
	// One-time post-connect read: init handshake (v2), then valid protocol traffic + settings snapshot.
	if (!this->_synced && !this->_refreshFuture.valid())
	{
		this->_refreshFuture.setFromAsync([this]() {
			if (!this->_initialized)
			{
				this->_headphones.initDevice();
				this->_initialized = true;
			}
			// requestAmbientState is protocol-aware (v1 uses 66 02, v2 uses 66 17) and read-only; sending it
			// immediately gives v1 devices the handshake traffic they need to stay powered on.
			this->_headphones.requestAmbientState();
			if (this->_isV2())
			{
				this->_headphones.requestBattery();
				this->_headphones.requestEqualizer();
				this->_headphones.requestDsee();
				this->_headphones.probeCapabilities();
			}
		});
	}

	if (this->_refreshFuture.valid() && this->_refreshFuture.ready())
	{
		try { this->_refreshFuture.get(); }
		catch (const RecoverableException& e) { if (e.shouldDisconnect) this->_bt.disconnect(); this->_mq.addMessage(e.what()); }
		catch (const std::exception& e) { this->_mq.addMessage(e.what()); }
		this->_syncUIFromHeadphones();
		this->_synced = true;
		this->_pollCounter = 0;
	}

	if (!this->_synced)
		return;

	// Poll the button-changeable ASM state so the app reflects changes made on the headphone itself.
	if (this->_pollFuture.valid() && this->_pollFuture.ready())
	{
		try { this->_pollFuture.get(); } catch (const std::exception&) {}
		if (!this->_sendCommandFuture.valid())
		{
			this->_uiAsmOn = this->_headphones.getAmbientSoundControl();
			int lvl = this->_headphones.getAsmLevel();
			this->_uiAsmMode = !this->_uiAsmOn ? 0 : (lvl > 0 ? 2 : 1);
			if (lvl > 0) this->_uiAsmLevel = lvl;
			this->_uiFocusOnVoice = this->_headphones.getFocusOnVoice();
		}
	}
	if (!this->_pollFuture.valid() && ++this->_pollCounter >= DYNAMIC_POLL_FRAMES)
	{
		this->_pollCounter = 0;
		this->_pollFuture.setFromAsync([this]() { this->_headphones.requestAmbientState(); });
	}
}

void CrossPlatformGUI::_syncUIFromHeadphones()
{
	this->_uiAsmOn = this->_headphones.getAmbientSoundControl();
	int lvl = this->_headphones.getAsmLevel();
	this->_uiAsmMode = !this->_uiAsmOn ? 0 : (lvl > 0 ? 2 : 1);
	this->_uiAsmLevel = lvl > 0 ? lvl : 10;
	this->_uiFocusOnVoice = this->_headphones.getFocusOnVoice();

	this->_uiEqPreset = (int)(unsigned char)this->_headphones.getEqualizerPreset();
	for (int i = 0; i < 5; ++i)
		this->_uiEqBands[i] = this->_headphones.getEqualizerBand(i);
	this->_uiClearBass = this->_headphones.getClearBass();
	this->_uiDsee = this->_headphones.getDsee();

	this->_uiAutoPowerOff = this->_headphones.getAutoPowerOff();
	this->_uiSpeakToChat = this->_headphones.getSpeakToChat();
	this->_uiAdaptiveVolume = this->_headphones.getAdaptiveVolume();
}

void CrossPlatformGUI::_drawStatusHeader()
{
	if (!this->_beginCard("##status")) { this->_endCard(); return; }

	ImGui::Text("%s", this->_connectedDevice.name.empty() ? "Sony Headphones" : this->_connectedDevice.name.c_str());
	ImGui::SameLine();
	ImGui::TextDisabled("(%s)", this->_isV2() ? "v2" : "v1");

	if (this->_headphones.hasDualBattery())
	{
		ImGui::Text("Battery   L %d%%    R %d%%", this->_headphones.getBatteryLeft(), this->_headphones.getBatteryRight());
		if (this->_headphones.getBatteryCase() >= 0)
			ImGui::Text("Case      %d%%", this->_headphones.getBatteryCase());
	}
	else
	{
		int batt = this->_headphones.getBatteryLevel();
		if (batt >= 0)
			ImGui::Text("Battery   %d%%%s", batt, this->_headphones.isBatteryCharging() ? "  (charging)" : "");
	}

	if (this->_headphones.hasCodec())
		ImGui::Text("Codec     %s", this->_headphones.getCodec().c_str());
	if (this->_headphones.hasFirmware())
		ImGui::TextDisabled("Firmware  %s", this->_headphones.getFirmware().c_str());

	this->_endCard();
}

void CrossPlatformGUI::_drawASMControls()
{
	if (!this->_beginCard("##asm")) { this->_endCard(); return; }
	this->_cardTitle("Ambient Sound");

	const char* modes[] = { "Off", "Noise Cancelling", "Ambient" };
	const float widths[] = { 110.f, 150.f, 120.f };
	for (int i = 0; i < 3; ++i)
	{
		if (i) ImGui::SameLine();
		bool sel = this->_uiAsmMode == i;
		if (sel) ImGui::PushStyleColor(ImGuiCol_Button, ImGui::GetStyle().Colors[ImGuiCol_ButtonActive]);
		if (ImGui::Button(modes[i], ImVec2(widths[i], 0)))
			this->_uiAsmMode = i;
		if (sel) ImGui::PopStyleColor();
	}

	if (this->_uiAsmMode == 2)
	{
		int maxLevel = this->_isV2() ? 20 : 19;
		if (this->_uiAsmLevel < 1) this->_uiAsmLevel = 1;
		if (this->_uiAsmLevel > maxLevel) this->_uiAsmLevel = maxLevel;
		ImGui::Spacing();
		ImGui::SetNextItemWidth(ImGui::GetContentRegionAvail().x);
		ImGui::SliderInt("##asmlevel", &this->_uiAsmLevel, 1, maxLevel, "Level %d");
		if (this->_headphones.isFocusOnVoiceAvailable())
			ImGui::Checkbox("Focus on Voice", &this->_uiFocusOnVoice);
	}

	// Map UI intent onto the desired state (mirrors the macOS applyMode); setChanges() sends only the diff.
	switch (this->_uiAsmMode)
	{
	case 0:
		this->_headphones.setAmbientSoundControl(false);
		break;
	case 1:
		this->_headphones.setAmbientSoundControl(true);
		this->_headphones.setAsmLevel(0);
		this->_headphones.setFocusOnVoice(false);
		break;
	case 2:
		this->_headphones.setAmbientSoundControl(true);
		this->_headphones.setAsmLevel(this->_uiAsmLevel < 1 ? 1 : this->_uiAsmLevel);
		this->_headphones.setFocusOnVoice(this->_uiFocusOnVoice);
		break;
	}

	this->_endCard();
}

void CrossPlatformGUI::_drawEqualizer()
{
	if (!this->_beginCard("##eq")) { this->_endCard(); return; }
	this->_cardTitle("Equalizer");

	static const struct { const char* name; int val; } presets[] = {
		{ "Off", 0x00 }, { "Bright", 0x10 }, { "Excited", 0x11 }, { "Mellow", 0x12 }, { "Relaxed", 0x13 },
		{ "Vocal", 0x14 }, { "Treble", 0x15 }, { "Bass", 0x16 }, { "Speech", 0x17 }, { "Manual", 0xA0 }
	};

	const float spacing = ImGui::GetStyle().ItemSpacing.x;
	const float cellW = (ImGui::GetContentRegionAvail().x - spacing * 4.f) / 5.f;
	for (int i = 0; i < 10; ++i)
	{
		if (i % 5) ImGui::SameLine();
		bool sel = this->_uiEqPreset == presets[i].val;
		if (sel) ImGui::PushStyleColor(ImGuiCol_Button, ImGui::GetStyle().Colors[ImGuiCol_ButtonActive]);
		if (ImGui::Button(presets[i].name, ImVec2(cellW, 0)))
		{
			this->_uiEqPreset = presets[i].val;
			int p = presets[i].val;
			this->_sendFeatureCommand([this, p]() { this->_headphones.setEqualizerPreset((EQ_PRESET)p); });
		}
		if (sel) ImGui::PopStyleColor();
	}

	if (this->_uiEqPreset == 0xA0)
	{
		ImGui::Spacing();
		const char* bandNames[] = { "Clear Bass", "400", "1k", "2.5k", "6.3k", "16k" };
		int* values[] = { &this->_uiClearBass, &this->_uiEqBands[0], &this->_uiEqBands[1],
						  &this->_uiEqBands[2], &this->_uiEqBands[3], &this->_uiEqBands[4] };
		bool changed = false;
		for (int i = 0; i < 6; ++i)
		{
			std::string id = "##eqband" + std::to_string(i);
			std::string fmt = std::string(bandNames[i]) + "   %d";
			ImGui::SetNextItemWidth(ImGui::GetContentRegionAvail().x);
			if (ImGui::SliderInt(id.c_str(), values[i], 0, 10, fmt.c_str()))
				changed = true;
		}
		if (changed)
		{
			std::vector<int> bands(this->_uiEqBands.begin(), this->_uiEqBands.end());
			int cb = this->_uiClearBass;
			this->_sendFeatureCommand([this, cb, bands]() { this->_headphones.setEqualizerCustom(cb, bands); });
		}
	}

	this->_endCard();
}

void CrossPlatformGUI::_drawDsee()
{
	if (!this->_beginCard("##dsee")) { this->_endCard(); return; }
	this->_cardTitle("DSEE Upscaling");

	if (ImGui::Checkbox("Enable DSEE", &this->_uiDsee))
	{
		bool v = this->_uiDsee;
		this->_sendFeatureCommand([this, v]() { this->_headphones.setDsee(v); });
	}

	this->_endCard();
}

void CrossPlatformGUI::_drawOptionalFeatures()
{
	const bool any = this->_headphones.hasAutoPowerOff() || this->_headphones.hasSpeakToChat() ||
					 this->_headphones.hasAdaptiveVolume();
	if (!any)
		return;

	if (!this->_beginCard("##features")) { this->_endCard(); return; }
	this->_cardTitle("Features");

	if (this->_headphones.hasAutoPowerOff())
	{
		ImGui::TextUnformatted("Auto Power-Off");
		ImGui::SetNextItemWidth(ImGui::GetContentRegionAvail().x);
		if (ImGui::Combo("##apo", &this->_uiAutoPowerOff,
			"Off\0After 5 min\0After 30 min\0After 1 hour\0After 3 hours\0When taken off\0\0"))
		{
			int idx = this->_uiAutoPowerOff;
			this->_sendFeatureCommand([this, idx]() { this->_headphones.setAutoPowerOff(idx); });
		}
	}

	if (this->_headphones.hasSpeakToChat())
	{
		if (ImGui::Checkbox("Speak-to-Chat", &this->_uiSpeakToChat))
		{
			bool v = this->_uiSpeakToChat;
			this->_sendFeatureCommand([this, v]() { this->_headphones.setSpeakToChat(v); });
		}
	}

	if (this->_headphones.hasAdaptiveVolume())
	{
		if (ImGui::Checkbox("Adaptive Volume Control", &this->_uiAdaptiveVolume))
		{
			bool v = this->_uiAdaptiveVolume;
			this->_sendFeatureCommand([this, v]() { this->_headphones.setAdaptiveVolume(v); });
		}
	}

	this->_endCard();
}

void CrossPlatformGUI::_drawSurroundControls()
{
	if (!this->_beginCard("##vpt")) { this->_endCard(); return; }
	this->_cardTitle("Virtual Sound");

	ImGui::TextDisabled("Only one may be used at a time");

	ImGui::SetNextItemWidth(ImGui::GetContentRegionAvail().x);
	if (ImGui::Combo("##pos", &this->_uiSoundPosition,
		"Off\0Front Left\0Front Right\0Front\0Rear Left\0Rear Right\0\0"))
		this->_uiVptType = 0;

	ImGui::SetNextItemWidth(ImGui::GetContentRegionAvail().x);
	if (ImGui::Combo("##vpt", &this->_uiVptType,
		"Off\0Outdoor Festival\0Arena\0Concert Hall\0Club\0\0"))
		this->_uiSoundPosition = 0;

	this->_headphones.setSurroundPosition(SOUND_POSITION_PRESET_ARRAY[this->_uiSoundPosition]);
	this->_headphones.setVptType(this->_uiVptType);

	this->_endCard();
}

void CrossPlatformGUI::_sendPendingASMChanges()
{
	if (this->_featureCommandFuture.valid() && this->_featureCommandFuture.ready())
	{
		try { this->_featureCommandFuture.get(); }
		catch (const RecoverableException& e) { if (e.shouldDisconnect) this->_bt.disconnect(); this->_mq.addMessage(e.what()); }
		catch (const std::exception& e) { this->_mq.addMessage(e.what()); }
	}

	if (this->_sendCommandFuture.valid() && this->_sendCommandFuture.ready())
	{
		try
		{
			this->_sendCommandFuture.get();
		}
		catch (const RecoverableException& exc)
		{
			std::string prefix;
			if (exc.shouldDisconnect)
			{
				this->_bt.disconnect();
				prefix = "Disconnected due to: ";
			}
			this->_mq.addMessage(prefix + exc.what());
		}
		catch (const std::exception& e) { this->_mq.addMessage(e.what()); }
	}
	else if (!this->_sendCommandFuture.valid() && this->_headphones.isChanged())
	{
		this->_sendCommandFuture.setFromAsync([this]() { this->_headphones.setChanges(); });
	}
}

bool CrossPlatformGUI::_beginCard(const char* id)
{
	return ImGui::BeginChild(id, ImVec2(0.f, 0.f),
		ImGuiChildFlags_Borders | ImGuiChildFlags_AutoResizeY | ImGuiChildFlags_AlwaysUseWindowPadding);
}

void CrossPlatformGUI::_endCard()
{
	ImGui::EndChild();
	ImGui::Spacing();
}

void CrossPlatformGUI::_cardTitle(const char* title)
{
	ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.55f, 0.63f, 0.72f, 1.0f));
	ImGui::TextUnformatted(title);
	ImGui::PopStyleColor();
	ImGui::Spacing();
}

void CrossPlatformGUI::_applyTheme()
{
	ImGui::StyleColorsDark();
	ImGuiStyle& s = ImGui::GetStyle();

	s.WindowRounding = 0.f;
	s.ChildRounding = 10.f;
	s.FrameRounding = 8.f;
	s.GrabRounding = 8.f;
	s.PopupRounding = 8.f;
	s.ScrollbarRounding = 8.f;
	s.WindowPadding = ImVec2(16, 16);
	s.FramePadding = ImVec2(12, 7);
	s.ItemSpacing = ImVec2(10, 10);
	s.ItemInnerSpacing = ImVec2(8, 6);
	s.ChildBorderSize = 1.f;

	const ImVec4 accent = ImVec4(0.26f, 0.55f, 0.96f, 1.00f);
	const ImVec4 accentHi = ImVec4(0.36f, 0.63f, 1.00f, 1.00f);

	ImVec4* c = s.Colors;
	c[ImGuiCol_WindowBg] = WINDOW_COLOR;
	c[ImGuiCol_ChildBg] = ImVec4(0.13f, 0.13f, 0.15f, 1.00f);
	c[ImGuiCol_PopupBg] = ImVec4(0.13f, 0.13f, 0.15f, 1.00f);
	c[ImGuiCol_Border] = ImVec4(1.f, 1.f, 1.f, 0.06f);
	c[ImGuiCol_FrameBg] = ImVec4(0.20f, 0.20f, 0.23f, 1.00f);
	c[ImGuiCol_FrameBgHovered] = ImVec4(0.25f, 0.25f, 0.29f, 1.00f);
	c[ImGuiCol_FrameBgActive] = ImVec4(0.28f, 0.28f, 0.32f, 1.00f);
	c[ImGuiCol_Text] = ImVec4(0.94f, 0.94f, 0.96f, 1.00f);
	c[ImGuiCol_TextDisabled] = ImVec4(0.50f, 0.50f, 0.56f, 1.00f);
	c[ImGuiCol_Button] = ImVec4(0.22f, 0.22f, 0.26f, 1.00f);
	c[ImGuiCol_ButtonHovered] = ImVec4(0.28f, 0.28f, 0.33f, 1.00f);
	c[ImGuiCol_ButtonActive] = accent;
	c[ImGuiCol_CheckMark] = accent;
	c[ImGuiCol_SliderGrab] = accent;
	c[ImGuiCol_SliderGrabActive] = accentHi;
	c[ImGuiCol_Header] = ImVec4(0.22f, 0.22f, 0.26f, 1.00f);
	c[ImGuiCol_HeaderHovered] = ImVec4(0.26f, 0.26f, 0.31f, 1.00f);
	c[ImGuiCol_HeaderActive] = accent;
	c[ImGuiCol_Separator] = ImVec4(1.f, 1.f, 1.f, 0.06f);
	c[ImGuiCol_ScrollbarBg] = ImVec4(0.f, 0.f, 0.f, 0.f);
}

CrossPlatformGUI::CrossPlatformGUI(BluetoothWrapper bt) : _bt(std::move(bt)), _headphones(_bt)
{
	this->_applyTheme();

	ImGuiIO& io = ImGui::GetIO();
	this->_mq = TimedMessageQueue(GUI_MAX_MESSAGES);
	this->_connectedDevicesFuture.setFromAsync([this]() { return this->_bt.getConnectedDevices(); });

	io.IniFilename = nullptr;
	io.WantSaveIniSettings = false;

	//AddFontFromMemory will own the pointer, so there's no leak
	char* fileData = new char[sizeof(CascadiaCodeTTF)];
	memcpy(fileData, CascadiaCodeTTF, sizeof(CascadiaCodeTTF));
	ImFont* font = io.Fonts->AddFontFromMemoryTTF(reinterpret_cast<void*>(fileData), sizeof(CascadiaCodeTTF), FONT_SIZE);
	IM_ASSERT(font != NULL);
}
