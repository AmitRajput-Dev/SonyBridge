#pragma once

// winsock2.h must precede windows.h, which bluetoothapis.h pulls in.
#include <winsock2.h>
#include <ws2bth.h>
// Lowercase: the MinGW-w64 headers are named this way, and so is the file on a
// case-sensitive filesystem (cross-compiling from Linux).
#include <bluetoothapis.h>
#include <rpc.h>

#include <atomic>
#include <string>

#include "IBluetoothConnector.h"
#include "ByteMagic.h"

// Only MSVC understands these; every other toolchain gets the libraries from CMake.
#ifdef _MSC_VER
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "rpcrt4.lib")
#pragma comment(lib, "bthprops.lib")
#endif

class WindowsBluetoothConnector final : public IBluetoothConnector
{
public:
	WindowsBluetoothConnector();

	~WindowsBluetoothConnector();

	virtual void connect(const std::string& addrStr) noexcept(false);
	virtual int send(char* buf, size_t length) noexcept(false);
	virtual int recv(char* buf, size_t length) noexcept(false);
	virtual void disconnect() noexcept;
	virtual bool isConnected() noexcept;

	virtual std::vector<BluetoothDevice> getConnectedDevices() noexcept(false);
	virtual SonyProtocolVersion getProtocolVersion() noexcept;

private:
	std::vector<BluetoothDevice> _findDevicesInRadio(BLUETOOTH_DEVICE_SEARCH_PARAMS* searchParams);
	std::string _wstringToUtf8(const std::wstring& wstr);
	bool _tryConnect(const char* uuid, SOCKADDR_BTH& sab);

	SOCKET _socket = INVALID_SOCKET;
	std::atomic<bool> _connected = false;
	SonyProtocolVersion _protocolVersion = SonyProtocolVersion::V1;
	void _initSocket();
};