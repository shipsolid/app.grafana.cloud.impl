using System.Diagnostics;

public class Instrumentation : IDisposable
{
    public Instrumentation(string activitySourceName)
    {
        this.ActivitySource = new ActivitySource(activitySourceName);
    }

    public ActivitySource ActivitySource { get; }

    public void Dispose()
    {
        this.ActivitySource?.Dispose();
    }
}
