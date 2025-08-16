namespace FakeStoreIngestor.Models;

public class Product
{
    // Use FakeStore's id as our PK
    public int Id { get; set; }
    public string Title { get; set; } = "";
    public decimal Price { get; set; }
    public string Description { get; set; } = "";
    public string Category { get; set; } = "";
    public string Image { get; set; } = "";

    public Rating? Rating { get; set; }
}
