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

var values = new Dictionary<string, object?>();
var sensorStatus = new Dictionary<string, string>();
var rrIntervals = new List<double>();
var valuesLock = new object();
var firstReading = new TaskCompletionSource(
    TaskCreationOptions.RunContinuationsAsynchronously
);

IBandSensor<IBandAccelerometerReading> accelerometer = client.SensorManager.Accelerometer;
IBandSensor<IBandGyroscopeReading> gyroscope = client.SensorManager.Gyroscope;
IBandSensor<IBandHeartRateReading> heartRate = client.SensorManager.HeartRate;
IBandSensor<IBandRRIntervalReading> rrInterval = client.SensorManager.RRInterval;
IBandSensor<IBandSkinTemperatureReading> skinTemperature = client.SensorManager.SkinTemperature;
IBandSensor<IBandPedometerReading> pedometer = client.SensorManager.Pedometer;
IBandSensor<IBandCaloriesReading> calories = client.SensorManager.Calories;
IBandSensor<IBandDistanceReading> distance = client.SensorManager.Distance;
IBandContactSensor contact = client.SensorManager.Contact;
IBandSensor<IBandUVReading> uv = client.SensorManager.UV;
IBandSensor<IBandGsrReading> gsr = client.SensorManager.Gsr;
IBandSensor<IBandAmbientLightReading> ambientLight = client.SensorManager.AmbientLight;
IBandSensor<IBandBarometerReading> barometer = client.SensorManager.Barometer;
IBandSensor<IBandAltimeterReading> altimeter = client.SensorManager.Altimeter;

accelerometer.ReadingChanged += (_, eventArgs) =>
{
    IBandAccelerometerReading reading = eventArgs.SensorReading;
    lock (valuesLock)
    {
        values["accelerometer"] = new
        {
            x = reading.AccelerationX,
            y = reading.AccelerationY,
            z = reading.AccelerationZ,
        };
    }
    firstReading.TrySetResult();
};

gyroscope.ReadingChanged += (_, eventArgs) =>
{
    IBandGyroscopeReading reading = eventArgs.SensorReading;
    lock (valuesLock)
    {
        values["gyroscope"] = new
        {
            x = reading.AngularVelocityX,
            y = reading.AngularVelocityY,
            z = reading.AngularVelocityZ,
        };
    }
};

heartRate.ReadingChanged += (_, eventArgs) =>
{
    IBandHeartRateReading reading = eventArgs.SensorReading;
    lock (valuesLock)
    {
        values["heartRateBpm"] = reading.HeartRate;
        values["heartRateQuality"] = reading.Quality.ToString();
    }
};

rrInterval.ReadingChanged += (_, eventArgs) =>
{
    lock (valuesLock)
    {
        rrIntervals.Add(eventArgs.SensorReading.Interval);
        values["rrIntervalMs"] = eventArgs.SensorReading.Interval;
    }
};

skinTemperature.ReadingChanged += (_, eventArgs) =>
{
    lock (valuesLock)
    {
        values["skinTemperatureCelsius"] = eventArgs.SensorReading.Temperature;
    }
};

pedometer.ReadingChanged += (_, eventArgs) =>
{
    IBandPedometerReading reading = eventArgs.SensorReading;
    lock (valuesLock)
    {
        values["steps"] = new
        {
            total = reading.TotalSteps,
            today = reading.StepsToday,
        };
    }
};

calories.ReadingChanged += (_, eventArgs) =>
{
    IBandCaloriesReading reading = eventArgs.SensorReading;
    lock (valuesLock)
    {
        values["calories"] = new
        {
            total = reading.Calories,
            today = reading.CaloriesToday,
        };
    }
};

distance.ReadingChanged += (_, eventArgs) =>
{
    IBandDistanceReading reading = eventArgs.SensorReading;
    lock (valuesLock)
    {
        values["distance"] = new
        {
            totalMeters = reading.TotalDistance,
            todayMeters = reading.DistanceToday,
            speedMetersPerSecond = reading.Speed,
            pace = reading.Pace,
            motion = reading.CurrentMotion.ToString(),
        };
    }
};

contact.ReadingChanged += (_, eventArgs) =>
{
    lock (valuesLock)
    {
        values["contact"] = eventArgs.SensorReading.State.ToString();
    }
};

uv.ReadingChanged += (_, eventArgs) =>
{
    IBandUVReading reading = eventArgs.SensorReading;
    lock (valuesLock)
    {
        values["ultraviolet"] = new
        {
            indexLevel = reading.IndexLevel.ToString(),
            exposureToday = reading.ExposureToday,
        };
    }
};

gsr.ReadingChanged += (_, eventArgs) =>
{
    lock (valuesLock)
    {
        values["galvanicSkinResponse"] = new
        {
            resistance = eventArgs.SensorReading.Resistance,
            unit = "ohms",
        };
    }
};

ambientLight.ReadingChanged += (_, eventArgs) =>
{
    lock (valuesLock)
    {
        values["ambientLight"] = new
        {
            brightness = eventArgs.SensorReading.Brightness,
        };
    }
};

barometer.ReadingChanged += (_, eventArgs) =>
{
    IBandBarometerReading reading = eventArgs.SensorReading;
    lock (valuesLock)
    {
        values["barometer"] = new
        {
            airPressure = reading.AirPressure,
            temperatureCelsius = reading.Temperature,
        };
    }
};

altimeter.ReadingChanged += (_, eventArgs) =>
{
    IBandAltimeterReading reading = eventArgs.SensorReading;
    lock (valuesLock)
    {
        values["altimeter"] = new
        {
            totalGain = reading.TotalGain,
            totalLoss = reading.TotalLoss,
            steppingGain = reading.SteppingGain,
            steppingLoss = reading.SteppingLoss,
            stepsAscended = reading.StepsAscended,
            stepsDescended = reading.StepsDescended,
            rate = reading.Rate,
            flightsAscended = reading.FlightsAscended,
            flightsDescended = reading.FlightsDescended,
            flightsAscendedToday = reading.FlightsAscendedToday,
            totalGainToday = reading.TotalGainToday,
        };
    }
};

var startedSensors = new List<(string Name, Func<Task> Stop)>();
try
{
    await StartSensorAsync("accelerometer", accelerometer, startedSensors, sensorStatus);
    await StartSensorAsync("gyroscope", gyroscope, startedSensors, sensorStatus);
    await StartSensorAsync("heartRate", heartRate, startedSensors, sensorStatus);
    await StartSensorAsync("rrInterval", rrInterval, startedSensors, sensorStatus);
    await StartSensorAsync("skinTemperature", skinTemperature, startedSensors, sensorStatus);
    await StartSensorAsync("pedometer", pedometer, startedSensors, sensorStatus);
    await StartSensorAsync("calories", calories, startedSensors, sensorStatus);
    await StartSensorAsync("distance", distance, startedSensors, sensorStatus);
    await StartSensorAsync("contact", contact, startedSensors, sensorStatus);
    await StartSensorAsync("uv", uv, startedSensors, sensorStatus);
    await StartSensorAsync("gsr", gsr, startedSensors, sensorStatus);
    await StartSensorAsync("ambientLight", ambientLight, startedSensors, sensorStatus);
    await StartSensorAsync("barometer", barometer, startedSensors, sensorStatus);
    await StartSensorAsync("altimeter", altimeter, startedSensors, sensorStatus);

    await firstReading.Task.WaitAsync(TimeSpan.FromSeconds(15));
    await Task.Delay(TimeSpan.FromSeconds(5));

    lock (valuesLock)
    {
        if (rrIntervals.Count >= 2)
        {
            values["heartRateVariability"] = new
            {
                rmssdMs = CalculateRmssd(rrIntervals),
                sampleCount = rrIntervals.Count,
            };
        }
    }

    var telemetry = new Dictionary<string, object?>
    {
        ["type"] = "telemetry",
        ["timestamp"] = DateTimeOffset.UtcNow,
        ["unsupported"] = new
        {
            spo2 = "not_available_on_microsoft_band_v1",
            respiratoryRate = "not_measured; requires validated derivation",
            sleepState = "not_available_from_live_sensor_api",
        },
        ["sensorStatus"] = sensorStatus,
    };
    lock (valuesLock)
    {
        foreach ((string key, object? value) in values)
        {
            telemetry[key] = value;
        }
    }
    Console.WriteLine(JsonSerializer.Serialize(telemetry));
}
catch (TimeoutException)
{
    Console.Error.WriteLine("Timed out waiting for Band accelerometer data.");
    return 4;
}
finally
{
    foreach ((_, Func<Task> stop) in startedSensors)
    {
        await stop();
    }
}

return 0;

static async Task StartSensorAsync<T>(
    string name,
    IBandSensor<T> sensor,
    List<(string Name, Func<Task> Stop)> startedSensors,
    Dictionary<string, string> sensorStatus
) where T : IBandSensorReading
{
    if (!sensor.IsSupported)
    {
        sensorStatus[name] = "not_supported";
        Console.Error.WriteLine($"Band sensor not supported: {name}");
        return;
    }

    try
    {
        if (!await sensor.StartReadingsAsync())
        {
            sensorStatus[name] = "subscription_rejected";
            Console.Error.WriteLine($"Band sensor subscription rejected: {name}");
            return;
        }

        sensorStatus[name] = "started";
        startedSensors.Add((name, sensor.StopReadingsAsync));
    }
    catch (Exception exception)
    {
        sensorStatus[name] = "unavailable";
        Console.Error.WriteLine($"Band sensor unavailable: {name}: {exception.Message}");
    }
}

static double CalculateRmssd(IEnumerable<double> intervals)
{
    double[] samples = intervals.ToArray();
    double squaredDifferenceSum = 0;
    for (int index = 1; index < samples.Length; index++)
    {
        double difference = samples[index] - samples[index - 1];
        squaredDifferenceSum += difference * difference;
    }

    return Math.Sqrt(squaredDifferenceSum / (samples.Length - 1));
}

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
