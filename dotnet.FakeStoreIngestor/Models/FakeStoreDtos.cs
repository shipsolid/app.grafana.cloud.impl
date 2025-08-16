namespace FakeStoreIngestor.Models;

public record FakeStoreProductDto(
    int id,
    string title,
    decimal price,
    string description,
    string category,
    string image,
    FakeStoreRating rating);

public record FakeStoreRating(double rate, int count);
