using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Microsoft.Band;
using Microsoft.Band.Sensors;

int sampleCount = int.Parse(GetArgument("--samples", "1"), CultureInfo.InvariantCulture);
double interval = double.Parse(GetArgument("--interval-seconds", "5"), CultureInfo.InvariantCulture);
bool continuous = args.Contains("--continuous");
if (sampleCount < 1 || !double.IsFinite(interval) || interval <= 0)
{
    throw new ArgumentException("Sample count and interval must be positive.");
}
if (args.Contains("--list-devices"))
{
    foreach (IBandInfo band in await BandClientManager.Instance.GetBandsAsync())
    {
        Console.WriteLine(JsonSerializer.Serialize(new { type = "device", name = band.Name }));
    }
    return 0;
}

string? selectedName = Environment.GetEnvironmentVariable("BAND_DEVICE_NAME");
IBandInfo[] bands = await BandClientManager.Instance.GetBandsAsync();
IBandInfo[] candidates = bands.Where(b =>
    string.IsNullOrWhiteSpace(selectedName) || b.Name == selectedName).ToArray();
if (candidates.Length != 1)
{
    Console.Error.WriteLine(
        $"Expected exactly one matching Band, found {candidates.Length}. "
        + "Use --list-devices and set BAND_DEVICE_NAME to an exact, unique name.");
    return 2;
}

using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    cancellation.Cancel();
};
using IBandClient client = await BandClientManager.Instance.ConnectAsync(candidates[0]);
Console.WriteLine(JsonSerializer.Serialize(new
{
    type = "device",
    name = candidates[0].Name,
    firmwareVersion = await client.GetFirmwareVersionAsync(),
    hardwareVersion = await client.GetHardwareVersionAsync(),
}));

var gate = new object();
var sensors = new Dictionary<string, SensorState>();
var stops = new List<Func<Task>>();
var rrIntervals = new Queue<double>();
try
{
    await Subscribe("accelerometer", client.SensorManager.Accelerometer, r => new
    {
        x = r.AccelerationX, y = r.AccelerationY, z = r.AccelerationZ,
    }, "g", 5);
    await Subscribe("gyroscope", client.SensorManager.Gyroscope, r => new
    {
        x = r.AngularVelocityX, y = r.AngularVelocityY, z = r.AngularVelocityZ,
    }, "deg/s", 5);
    bool allowHeartRate = string.Equals(
        Environment.GetEnvironmentVariable("BAND_ALLOW_HEART_RATE"),
        "true", StringComparison.OrdinalIgnoreCase);
    await Subscribe("heartRate", client.SensorManager.HeartRate, r => new
    {
        bpm = r.HeartRate, quality = r.Quality.ToString(),
    }, "beats/min", 15, allowHeartRate);
    await Subscribe("rrInterval", client.SensorManager.RRInterval, r =>
    {
        // The SDK reports RR intervals in seconds; publish milliseconds.
        double milliseconds = r.Interval * 1000;
        rrIntervals.Enqueue(milliseconds);
        while (rrIntervals.Count > 256)
        {
            rrIntervals.Dequeue();
        }
        return milliseconds;
    }, "ms", 15, allowHeartRate);
    await Subscribe("skinTemperature", client.SensorManager.SkinTemperature,
        r => r.Temperature, "Cel", 60);
    await Subscribe("pedometer", client.SensorManager.Pedometer,
        r => new { total = r.TotalSteps, today = r.StepsToday }, "steps", 120);
    await Subscribe("calories", client.SensorManager.Calories,
        r => new { total = r.Calories, today = r.CaloriesToday }, "kcal", 120);
    await Subscribe("distance", client.SensorManager.Distance, r => new
    {
        totalMeters = r.TotalDistance / 100.0,
        todayMeters = r.DistanceToday / 100.0,
        speedMetersPerSecond = r.Speed / 100.0,
        paceSecondsPerMeter = r.Pace / 1000.0,
        motion = r.CurrentMotion.ToString(),
    }, "SI", 120);
    await Subscribe("contact", client.SensorManager.Contact,
        r => r.State.ToString(), null, 60);
    await Subscribe("uv", client.SensorManager.UV,
        r => new { indexLevel = r.IndexLevel.ToString(), exposureToday = r.ExposureToday },
        null, 120);
    await Subscribe("gsr", client.SensorManager.Gsr, r => r.Resistance, "ohm", 60);
    await Subscribe("ambientLight", client.SensorManager.AmbientLight,
        r => r.Brightness, null, 60);
    await Subscribe("barometer", client.SensorManager.Barometer,
        r => new { airPressure = r.AirPressure, temperatureCelsius = r.Temperature },
        null, 60);
    await Subscribe("altimeter", client.SensorManager.Altimeter, r => new
    {
        totalGain = r.TotalGain, totalLoss = r.TotalLoss,
        steppingGain = r.SteppingGain, steppingLoss = r.SteppingLoss,
        stepsAscended = r.StepsAscended, stepsDescended = r.StepsDescended,
        rate = r.Rate, flightsAscended = r.FlightsAscended,
        flightsDescended = r.FlightsDescended,
        flightsAscendedToday = r.FlightsAscendedToday, totalGainToday = r.TotalGainToday,
    }, null, 120);

    // Keep subscriptions alive across snapshots, including heart-rate acquisition.
    DateTimeOffset startedAt = DateTimeOffset.UtcNow;
    for (int sample = 0; continuous || sample < sampleCount; sample++)
    {
        await Task.Delay(TimeSpan.FromSeconds(interval), cancellation.Token);
        Dictionary<string, object> snapshot;
        lock (gate)
        {
            SensorState motion = sensors["accelerometer"];
            if ((motion.ReceivedAt is null
                    && (DateTimeOffset.UtcNow - startedAt).TotalSeconds > 20)
                || (motion.ReceivedAt is not null
                    && Stopwatch.GetElapsedTime(motion.Ticks).TotalSeconds > 20))
            {
                throw new TimeoutException("Band motion stream stopped; reconnect required.");
            }
            snapshot = sensors.ToDictionary(p => p.Key, p => p.Value.Snapshot());
            SensorState rr = sensors["rrInterval"];
            if (rrIntervals.Count >= 2 && rr.ReceivedAt is not null
                && Stopwatch.GetElapsedTime(rr.Ticks).TotalSeconds <= rr.StaleAfterSeconds)
            {
                double[] samples = rrIntervals.ToArray();
                double sum = samples.Zip(samples.Skip(1), (a, b) => (b - a) * (b - a)).Sum();
                snapshot["heartRateVariability"] = new
                {
                    status = "fresh", value = Math.Sqrt(sum / (samples.Length - 1)),
                    unit = "ms", method = "RMSSD", sampleCount = samples.Length,
                    receivedAt = rr.ReceivedAt, timestampBasis = "gateway_receipt",
                    ageMs = Stopwatch.GetElapsedTime(rr.Ticks).TotalMilliseconds,
                };
            }
        }
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            type = "telemetry", schemaVersion = 2,
            timestamp = DateTimeOffset.UtcNow, bandName = candidates[0].Name,
            sensors = snapshot,
            unsupported = new
            {
                spo2 = "not_available_on_microsoft_band_v1",
                respiratoryRate = "not_measured",
                sleepState = "not_available_from_live_sensor_api",
            },
        }));
    }
}
catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
{
    Console.Error.WriteLine("Band stream stopped.");
}
finally
{
    foreach (Func<Task> stop in stops)
    {
        try
        {
            await stop().WaitAsync(TimeSpan.FromSeconds(3));
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"Sensor cleanup failed: {error.Message}");
        }
    }
}
return 0;

async Task Subscribe<T>(
    string name, IBandSensor<T> sensor, Func<T, object> map,
    string? unit, double staleAfterSeconds, bool consent = true
) where T : IBandSensorReading
{
    var state = new SensorState(unit, staleAfterSeconds);
    sensors[name] = state;
    if (!sensor.IsSupported)
    {
        state.Status = "not_supported";
        return;
    }
    if (!consent)
    {
        state.Status = "consent_required";
        return;
    }
    sensor.ReadingChanged += (_, eventArgs) =>
    {
        lock (gate)
        {
            state.Value = map(eventArgs.SensorReading);
            state.SourceTimestamp = eventArgs.SensorReading.Timestamp;
            state.ReceivedAt = DateTimeOffset.UtcNow;
            state.Ticks = Stopwatch.GetTimestamp();
        }
    };
    try
    {
        bool accepted = await sensor.StartReadingsAsync();
        state.Status = accepted ? "awaiting_reading" : "subscription_rejected";
        if (accepted)
        {
            stops.Add(sensor.StopReadingsAsync);
        }
        else
        {
            Console.Error.WriteLine($"Sensor subscription rejected: {name}");
        }
    }
    catch (Exception error)
    {
        state.Status = "unavailable";
        Console.Error.WriteLine($"Sensor unavailable: {name}: {error.Message}");
    }
}

string GetArgument(string name, string fallback)
{
    int index = Array.IndexOf(args, name);
    if (index < 0) return fallback;
    if (index + 1 >= args.Length) throw new ArgumentException($"Missing value for {name}.");
    return args[index + 1];
}

internal sealed class SensorState(string? unit, double staleAfterSeconds)
{
    public string Status { get; set; } = "awaiting_reading";
    public object? Value { get; set; }
    public DateTimeOffset? SourceTimestamp { get; set; }
    public DateTimeOffset? ReceivedAt { get; set; }
    public long Ticks { get; set; }
    public double StaleAfterSeconds { get; } = staleAfterSeconds;

    public object Snapshot()
    {
        double? age = ReceivedAt is null ? null : Stopwatch.GetElapsedTime(Ticks).TotalMilliseconds;
        bool fresh = age is not null && age <= StaleAfterSeconds * 1000;
        return new
        {
            status = ReceivedAt is null ? Status : fresh ? "fresh" : "stale",
            value = fresh ? Value : null,
            unit,
            observedAt = SourceTimestamp,
            receivedAt = ReceivedAt,
            timestampBasis = "gateway_receipt",
            ageMs = age,
            staleAfterMs = StaleAfterSeconds * 1000,
        };
    }
}
