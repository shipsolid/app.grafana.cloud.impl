using FakeStoreIngestor.Models;
using Microsoft.EntityFrameworkCore;

namespace FakeStoreIngestor.Data;

public class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<Product> Products => Set<Product>();
    public DbSet<Rating> Ratings => Set<Rating>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Product>(e =>
        {
            e.HasKey(p => p.Id);
            e.Property(p => p.Title).IsRequired().HasMaxLength(256);
            e.Property(p => p.Category).HasMaxLength(128);

            e.HasOne(p => p.Rating)
             .WithOne()
             .HasForeignKey<Rating>(r => r.ProductId)
             .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<Rating>(e =>
        {
            e.HasKey(r => r.Id);
        });
    }
}
