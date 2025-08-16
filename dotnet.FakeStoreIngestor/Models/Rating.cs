namespace FakeStoreIngestor.Models;

public class Rating
{
    public int Id { get; set; }
    public double Rate { get; set; }
    public int Count { get; set; }

    // 1-1 with Product
    public int ProductId { get; set; }
}
