using System.Text.Json;
using Microsoft.Band;
using Microsoft.Band.Sensors;

int sampleCount = ParseSampleCount(args);
IBandInfo[] bands = await BandClientManager.Instance.GetBandsAsync();
if (bands.Length == 0)
{
    Console.Error.WriteLine("No paired Microsoft Band was found.");
    return 2;
}

using IBandClient client = await BandClientManager.Instance.ConnectAsync(bands[0]);
Console.WriteLine(JsonSerializer.Serialize(new
{
    type = "device",
    name = bands[0].Name,
    firmwareVersion = await client.GetFirmwareVersionAsync(),
    hardwareVersion = await client.GetHardwareVersionAsync(),
}));

IBandSensor<IBandAccelerometerReading> accelerometer =
    client.SensorManager.Accelerometer;
var readingsCompleted = new TaskCompletionSource(
    TaskCreationOptions.RunContinuationsAsynchronously
);
int readings = 0;

accelerometer.ReadingChanged += (_, eventArgs) =>
{
    int currentReading = Interlocked.Increment(ref readings);
    if (currentReading > sampleCount)
    {
        return;
    }

    Console.WriteLine(JsonSerializer.Serialize(new
    {
        type = "telemetry",
        timestamp = eventArgs.SensorReading.Timestamp,
        accelerometer = new
        {
            x = eventArgs.SensorReading.AccelerationX,
            y = eventArgs.SensorReading.AccelerationY,
            z = eventArgs.SensorReading.AccelerationZ,
        },
    }));

    if (currentReading == sampleCount)
    {
        readingsCompleted.TrySetResult();
    }
};

if (!await accelerometer.StartReadingsAsync())
{
    Console.Error.WriteLine("The Band rejected the accelerometer subscription.");
    return 3;
}

try
{
    await readingsCompleted.Task.WaitAsync(TimeSpan.FromSeconds(15));
}
catch (TimeoutException)
{
    Console.Error.WriteLine("Timed out waiting for Band accelerometer data.");
    return 4;
}
finally
{
    await accelerometer.StopReadingsAsync();
}

return 0;

static int ParseSampleCount(string[] arguments)
{
    int index = Array.FindIndex(
        arguments,
        argument => argument.Equals("--samples", StringComparison.OrdinalIgnoreCase)
    );
    if (index < 0)
    {
        return 1;
    }
    if (index + 1 >= arguments.Length
        || !int.TryParse(arguments[index + 1], out int count)
        || count < 1)
    {
        throw new ArgumentException("--samples must be followed by a positive integer.");
    }
    return count;
}
