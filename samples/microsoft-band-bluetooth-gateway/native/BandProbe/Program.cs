using System.Text.Json;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Devices.Enumeration;
using Windows.Networking.Sockets;

const string foregroundServiceUuid = "a502ca9a-2ba5-413c-a4e0-13804e47b38f";

bool connect = args.Contains("--connect", StringComparer.OrdinalIgnoreCase);
RfcommServiceId serviceId = RfcommServiceId.FromUuid(Guid.Parse(foregroundServiceUuid));
string selector = RfcommDeviceService.GetDeviceSelector(serviceId);
DeviceInformationCollection devices = await DeviceInformation.FindAllAsync(selector);

var result = new ProbeResult(
    foregroundServiceUuid,
    devices.Select(device => new ProbeDevice(device.Name, device.Id)).ToArray()
);

Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions
{
    WriteIndented = true,
}));

if (devices.Count == 0)
{
    Console.Error.WriteLine(
        "No paired Microsoft Band foreground RFCOMM service was found. "
        + "Confirm that the Band is powered on and paired in Windows."
    );
    return 2;
}

if (!connect)
{
    Console.WriteLine("Service discovery succeeded. Use --connect to test opening the RFCOMM channel.");
    return 0;
}

using RfcommDeviceService? service = await RfcommDeviceService.FromIdAsync(devices[0].Id);
if (service is null)
{
    Console.Error.WriteLine(
        "Windows found the Band service but denied access to it. "
        + "Check Bluetooth privacy permissions and pairing."
    );
    return 3;
}

using var socket = new StreamSocket();
await socket.ConnectAsync(
    service.ConnectionHostName,
    service.ConnectionServiceName,
    SocketProtectionLevel.BluetoothEncryptionAllowNullAuthentication
);

Console.WriteLine($"Connected to {devices[0].Name}.");
return 0;

internal sealed record ProbeDevice(string Name, string Id);

internal sealed record ProbeResult(string ServiceUuid, ProbeDevice[] Devices);
