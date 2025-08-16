using System.Net.Http.Json;
using FakeStoreIngestor.Data;
using FakeStoreIngestor.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.OpenApi.Models;
using Pomelo.EntityFrameworkCore.MySql.Infrastructure;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetry.Exporter;
using OpenTelemetry.Instrumentation.AspNetCore;
using OpenTelemetry.Instrumentation.Http;
using Prometheus;
using System.Diagnostics;

var builder = WebApplication.CreateBuilder(args);

// ------------------------
// Configuration
// ------------------------
var cs = builder.Configuration.GetConnectionString("Default")
    ?? throw new InvalidOperationException("ConnectionStrings:Default is missing.");
var baseUrl = builder.Configuration["Ingest:BaseUrl"] ?? "https://fakestoreapi.com/";
var productsEndpoint = builder.Configuration["Ingest:ProductsEndpoint"] ?? "products";

// ------------------------
// Instrumentation Changes Start
// ------------------------
string serviceName = Environment.GetEnvironmentVariable("OTEL_SERVICE_NAME")
    ?? throw new InvalidOperationException("OTEL_SERVICE_NAME is not set");
string OTEL_EXPORTER_OTLP_ENDPOINT = Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT")
    ?? throw new InvalidOperationException("OTEL_EXPORTER_OTLP_ENDPOINT is not set");
string OTEL_RESOURCE_ATTRIBUTES = Environment.GetEnvironmentVariable("OTEL_RESOURCE_ATTRIBUTES")
    ?? throw new InvalidOperationException("OTEL_RESOURCE_ATTRIBUTES is not set");
string apps = serviceName;
builder.Services.Configure<OtlpExporterOptions>("tracing", builder.Configuration.GetSection("OpenTelemetry:tracing:otlp"));
builder.Services.Configure<OtlpExporterOptions>("metrics", builder.Configuration.GetSection("OpenTelemetry:metrics:otlp"));
builder.Services.Configure<OtlpExporterOptions>("logging", builder.Configuration.GetSection("OpenTelemetry:logging:otlp"));
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
builder.Logging.AddOpenTelemetry(options =>
{
    options.IncludeScopes = true;
    options.SetResourceBuilder(
        ResourceBuilder.CreateDefault()
            .AddService(serviceName: serviceName)
            .AddAttributes(new []
                {
                    new KeyValuePair<string, object>("loki.resource.labels", "apps"),
                    new KeyValuePair<string, object>("apps", apps),
                }
            )
    );
    options.AddConsoleExporter();
    options.AddOtlpExporter(
        "logging",
        options => 
        {
            options.Protocol = OtlpExportProtocol.Grpc;
            options.Endpoint = new Uri(OTEL_EXPORTER_OTLP_ENDPOINT);
        }
    );
});
builder.Services.AddOpenTelemetry()
    .ConfigureResource(
        resource => resource
        .AddService(serviceName: serviceName)
        .AddAttributes(new Dictionary<string, object>
            {
                { "deployment.environment", OTEL_RESOURCE_ATTRIBUTES }
            }
        )
    )
    .WithTracing(
        tracing => tracing
        .AddSource(serviceName)
        .AddAspNetCoreInstrumentation(
            options =>
            {
                options.EnrichWithHttpRequest = (activity, httpRequest) =>
                {
                    activity.SetTag("app.name", apps);
                    activity.SetTag("deployment.environment", OTEL_RESOURCE_ATTRIBUTES);
                    activity.SetTag("http.method", httpRequest.Method);
                    activity.SetTag("http.path", httpRequest.Path);
                    activity.SetTag("user.agent", httpRequest.Headers["User-Agent"].ToString());
                    activity.SetTag("client.ip", httpRequest.HttpContext.Connection.RemoteIpAddress?.ToString());
                };
                options.EnrichWithHttpResponse = (activity, httpResponse) =>
                {
                    activity.SetTag("http.status_code", httpResponse.StatusCode);
                };
                options.EnrichWithException = (activity, exception) =>
                {
                    activity.SetTag("otel.status_code", "ERROR");
                    activity.SetTag("otel.status_description", exception.Message);
                };
            }
        )
        .AddSqlClientInstrumentation(
            options =>
            {
                options.SetDbStatementForText = true; // Adds SQL query as a tag (optional but useful)
            }
        )
        .AddHttpClientInstrumentation()
        .AddConsoleExporter()
        .AddOtlpExporter(
            "tracing",
            options => {
                options.Protocol = OtlpExportProtocol.Grpc;
                options.Endpoint = new Uri(OTEL_EXPORTER_OTLP_ENDPOINT);
            }
        )
    )
    .WithMetrics(
        metrics => metrics
        .AddMeter(serviceName)
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddConsoleExporter()
        .AddOtlpExporter(
            "metrics",
            options => {
                options.Protocol = OtlpExportProtocol.Grpc;
                options.Endpoint = new Uri(OTEL_EXPORTER_OTLP_ENDPOINT);
            }
        )
    );
builder.Services.AddSingleton(new Instrumentation(serviceName));
// ------------------------
// Instrumentation Changes End
// ------------------------

// ------------------------
// Services
// ------------------------
var sb = new MySqlConnector.MySqlConnectionStringBuilder(cs) { Password = "" };
Console.WriteLine($"[DB] Host={sb.Server}; Port={sb.Port}; Db={sb.Database}");

builder.Services.AddDbContext<AppDbContext>(opt =>
{
    // Pin server version; avoid AutoDetect() at startup
    var serverVersion = new MySqlServerVersion(new Version(8, 4, 0)); // match your MySQL image
    opt.UseMySql(cs, serverVersion, my =>
        my.EnableRetryOnFailure(
            maxRetryCount: 5,
            maxRetryDelay: TimeSpan.FromSeconds(10),
            errorNumbersToAdd: null));
});

builder.Services.AddHttpClient("fakestore", c =>
{
    c.BaseAddress = new Uri(baseUrl);
});

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(o =>
{
    o.SwaggerDoc("v1", new OpenApiInfo { Title = "FakeStore Ingestor", Version = "v1" });
});

var app = builder.Build();


// ------------------------
// Instrumentation Changes Start
// -------------------------
// app.UseRouting();
// Enable Prometheus metrics collection -- Added
app.UseHttpMetrics();   // Auto-captures request metrics
// app.MapMetrics("/metrics");
app.UseMetricServer();  // Exposes metrics at /metrics
// // Auth middleware
// app.UseAuthorization();
// ------------------------
// Instrumentation Changes End
// ------------------------


// ------------------------
// Database bootstrapping
// ------------------------
// For demos: create schema if it doesn't exist. For production, prefer migrations.
// Database bootstrapping (demo). Prefer migrations in prod.
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

    // Light retry so startup doesn’t die if MySQL is a bit slow
    var attempts = 0;
    while (true)
    {
        try
        {
            await db.Database.EnsureCreatedAsync();
            break;
        }
        catch (Exception ex) when (attempts++ < 10)
        {
            Console.WriteLine($"EnsureCreated retry {attempts}/10: {ex.Message}");
            await Task.Delay(TimeSpan.FromSeconds(3));
        }
    }
}

// ------------------------
// Middleware
// ------------------------

app.UseSwagger();
app.UseSwaggerUI();

// ------------------------
// Endpoints
// ------------------------

// Health
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

// Import/Upsert from FakeStore (all or first N)
app.MapPost("/import/{count?}", async (int? count, IHttpClientFactory httpFactory, AppDbContext db) =>
{
    var http = httpFactory.CreateClient("fakestore");
    var items = await http.GetFromJsonAsync<List<FakeStoreProductDto>>(productsEndpoint);
    if (items is null) return Results.Problem("Failed to fetch products from FakeStore API.");

    if (count is > 0) items = items.Take(count.Value).ToList();

    foreach (var dto in items)
    {
        var existing = await db.Products.Include(p => p.Rating)
                                        .FirstOrDefaultAsync(p => p.Id == dto.id);

        if (existing is null)
        {
            db.Products.Add(new Product
            {
                Id = dto.id,
                Title = dto.title,
                Price = dto.price,
                Description = dto.description,
                Category = dto.category,
                Image = dto.image,
                Rating = new Rating { Rate = dto.rating.rate, Count = dto.rating.count }
            });
        }
        else
        {
            existing.Title = dto.title;
            existing.Price = dto.price;
            existing.Description = dto.description;
            existing.Category = dto.category;
            existing.Image = dto.image;

            existing.Rating ??= new Rating { ProductId = existing.Id };
            existing.Rating.Rate = dto.rating.rate;
            existing.Rating.Count = dto.rating.count;
        }
    }

    var saved = await db.SaveChangesAsync();
    return Results.Ok(new { imported = items.Count, saved });
})
.WithSummary("Fetches products from fakestoreapi.com and stores/updates them in MySQL. Optional 'count' limits records.");

// Query all
app.MapGet("/products", async (AppDbContext db) =>
    await db.Products.AsNoTracking().Include(p => p.Rating).ToListAsync());

// Query by id
app.MapGet("/products/{id:int}", async (int id, AppDbContext db) =>
{
    var p = await db.Products.AsNoTracking().Include(p => p.Rating)
                             .FirstOrDefaultAsync(p => p.Id == id);
    return p is null ? Results.NotFound() : Results.Ok(p);
});

app.Run();
