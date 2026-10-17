using Microsoft.Band.Tiles;

namespace Microsoft.Band;

internal sealed class StoreApplicationPlatformProvider : IApplicationPlatformProvider
{
    private static readonly IApplicationPlatformProvider CurrentProvider =
        new StoreApplicationPlatformProvider();
    private static readonly bool AllowHeartRate =
        string.Equals(
            Environment.GetEnvironmentVariable("BAND_ALLOW_HEART_RATE"),
            "true",
            StringComparison.OrdinalIgnoreCase
        );

    private StoreApplicationPlatformProvider()
    {
    }

    public static IApplicationPlatformProvider Current => CurrentProvider;

    public Task<Guid> GetApplicationIdAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        return Task.FromResult(
            Guid.Parse("8942f7e6-8c52-4aa4-8c36-77c6bc4a9b5d")
        );
    }

    public Task<bool> GetAddTileConsentAsync(
        BandTile tile,
        CancellationToken token
    )
    {
        token.ThrowIfCancellationRequested();
        return Task.FromResult(false);
    }

    public UserConsent GetCurrentSensorConsent(Type sensorType) =>
        AllowHeartRate && sensorType.Name == "HeartRateSensor"
            ? UserConsent.Granted
            : UserConsent.NotSpecified;

    public Task<bool> RequestSensorConsentAsync(
        Type sensorType,
        string prompt,
        CancellationToken token
    )
    {
        token.ThrowIfCancellationRequested();
        return Task.FromResult(
            AllowHeartRate && sensorType.Name == "HeartRateSensor"
        );
    }
}
