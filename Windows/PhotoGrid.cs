using System.ComponentModel;
using System.Drawing.Drawing2D;

namespace PhotoSlideshow;

internal sealed class PhotoGrid : ScrollableControl
{
    private const int WidthPerTile = 152;
    private const int HeightPerTile = 120;
    private const int Gap = 8;
    private static readonly SemaphoreSlim Decoders = new(4);
    private readonly PhotoFile[] photos;
    private readonly Func<int, bool> favorite;
    private readonly int current;
    private readonly Dictionary<int, Bitmap?> previews = [];
    private readonly Dictionary<int, CancellationTokenSource> pending = [];
    private int[] visibleIndices = [];
    private HashSet<int> visibleWindow = [];
    private readonly Font heart = new("Segoe UI Symbol", 13);

    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Action<int>? OpenPhoto { get; set; }
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    internal Action<int>? RemoveFavorite { get; set; }

    public PhotoGrid(PhotoFile[] photos, int current, Func<int, bool> favorite)
    {
        this.photos = photos;
        this.current = current;
        this.favorite = favorite;
        visibleIndices = Enumerable.Range(0, photos.Length).ToArray();
        AccessibleName = "サムネイル一覧";
        AutoScroll = true;
        DoubleBuffered = true;
        ResizeRedraw = true;
        BackColor = Color.FromArgb(24, 25, 28);
    }

    private int Columns => Math.Max(1, (ClientSize.Width - Gap - SystemInformation.VerticalScrollBarWidth) / WidthPerTile);

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        UpdateScrollSize();
    }

    protected override void OnScroll(ScrollEventArgs se)
    {
        base.OnScroll(se);
        Invalidate();
    }

    private void UpdateScrollSize()
    {
        AutoScrollMinSize = new Size(0, (visibleIndices.Length + Columns - 1) / Columns * HeightPerTile + Gap);
        Invalidate();
    }

    public void Filter(bool onlyFavorites, bool keepOffset)
    {
        var offset = -AutoScrollPosition.Y;
        visibleIndices = Enumerable.Range(0, photos.Length).Where(i => !onlyFavorites || favorite(i)).ToArray();
        UpdateScrollSize();
        if (keepOffset) AutoScrollPosition = new Point(0, offset);
        else ScrollToCurrent();
    }

    public void ScrollToCurrent()
    {
        int index = Array.IndexOf(visibleIndices, current);
        AutoScrollPosition = new Point(0, index < 0 ? 0 : Math.Max(0, index / Columns * HeightPerTile - Height / 2));
        Invalidate();
    }

    private Rectangle Tile(int position)
    {
        int column = position % Columns;
        int row = position / Columns;
        return new Rectangle(Gap + column * WidthPerTile, Gap + row * HeightPerTile + AutoScrollPosition.Y,
            WidthPerTile - Gap, HeightPerTile - Gap);
    }
    private static Rectangle Badge(Rectangle tile) => new(tile.Right - 30, tile.Top + 5, 25, 25);

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        int first = Math.Max(0, (-AutoScrollPosition.Y - Gap) / HeightPerTile) * Columns;
        int last = Math.Min(visibleIndices.Length, first + (Height / HeightPerTile + 2) * Columns);
        visibleWindow = visibleIndices.Skip(first).Take(Math.Max(0, last - first)).ToHashSet();
        foreach (int key in pending.Keys.Where(x => !visibleWindow.Contains(x)).ToArray())
        {
            pending[key].Cancel();
            pending.Remove(key);
        }
        foreach (int key in previews.Keys.Where(x => !visibleWindow.Contains(x)).ToArray())
        {
            previews[key]?.Dispose();
            previews.Remove(key);
        }

        e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        using var shade = new SolidBrush(Color.FromArgb(42, 43, 48));
        using var outline = new Pen(Color.DodgerBlue, 3);
        for (int position = first; position < last; position++)
        {
            int index = visibleIndices[position];
            Rectangle tile = Tile(position);
            e.Graphics.FillRectangle(shade, tile);
            if (previews.TryGetValue(index, out Bitmap? image))
            {
                if (image is not null)
                {
                    float scale = Math.Min((tile.Width - 10f) / image.Width, (tile.Height - 10f) / image.Height);
                    float w = image.Width * scale, h = image.Height * scale;
                    e.Graphics.DrawImage(image, new RectangleF(tile.X + (tile.Width - w) / 2,
                        tile.Y + (tile.Height - h) / 2, w, h));
                }
            }
            else if (!pending.ContainsKey(index)) LoadPreview(index);
            if (index == current) e.Graphics.DrawRectangle(outline, Rectangle.Inflate(tile, -2, -2));
            if (favorite(index))
            {
                var badge = Badge(tile);
                e.Graphics.FillEllipse(Brushes.Black, badge);
                TextRenderer.DrawText(e.Graphics, "♥", heart, badge, Color.HotPink,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }
    }

    private async void LoadPreview(int index)
    {
        using var request = new CancellationTokenSource();
        pending[index] = request;
        Bitmap? result = null;
        try
        {
            result = await Task.Run(async () =>
            {
                await Decoders.WaitAsync(request.Token);
                try
                {
                    request.Token.ThrowIfCancellationRequested();
                    using var stream = File.OpenRead(photos[index].FullPath);
                    using var image = Image.FromStream(stream);
                    PlaybackSurface.Orient(image);
                    float scale = Math.Min(1, Math.Min(300f / image.Width, 220f / image.Height));
                    return new Bitmap(image, Math.Max(1, (int)(image.Width * scale)),
                        Math.Max(1, (int)(image.Height * scale)));
                }
                finally { Decoders.Release(); }
            });
        }
        catch (Exception failure) when (failure is OperationCanceledException or IOException or UnauthorizedAccessException
                                        or ArgumentException or OutOfMemoryException or System.Runtime.InteropServices.ExternalException) { }
        if (pending.TryGetValue(index, out var currentRequest) && currentRequest == request)
        {
            pending.Remove(index);
            if (!IsDisposed && visibleWindow.Contains(index))
            {
                previews[index] = result;
                Invalidate();
                return;
            }
        }
        result?.Dispose();
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        if (e.Button != MouseButtons.Left) return;
        int x = e.X - Gap, y = e.Y - Gap - AutoScrollPosition.Y;
        int column = x / WidthPerTile;
        if (x < 0 || y < 0 || column >= Columns) return;
        int position = y / HeightPerTile * Columns + column;
        if (position >= visibleIndices.Length || !Tile(position).Contains(e.Location)) return;
        int index = visibleIndices[position];
        if (favorite(index) && Badge(Tile(position)).Contains(e.Location))
        {
            if (MessageBox.Show(FindForm(), "この写真をお気に入りから解除しますか？", "お気に入りの解除",
                                MessageBoxButtons.YesNo) == DialogResult.Yes) RemoveFavorite?.Invoke(index);
        }
        else OpenPhoto?.Invoke(index);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            foreach (var request in pending.Values) request.Cancel();
            pending.Clear();
            foreach (var image in previews.Values) image?.Dispose();
            previews.Clear();
            heart.Dispose();
        }
        base.Dispose(disposing);
    }
}
