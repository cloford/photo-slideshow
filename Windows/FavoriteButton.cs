namespace PhotoSlideshow;

internal sealed class FavoriteButton : Button
{
    private const int LeftDown = 0x0201;
    private const int LeftUp = 0x0202;
    private const int LeftDoubleClick = 0x0203;
    private (long Time, Point Point)? previousClick;
    private bool acceptedDown;
    private bool skipUp;

    protected override void WndProc(ref Message message)
    {
        // A native button can receive the second press as either DOWN or DBLCLK.
        // Filtering at the button keeps the click away from playback and preserves keyboard activation.
        if (message.Msg is LeftDown or LeftDoubleClick)
        {
            var point = Cursor.Position;
            var tolerance = SystemInformation.DoubleClickSize;
            skipUp = previousClick is { } prior &&
                Environment.TickCount64 - prior.Time <= SystemInformation.DoubleClickTime &&
                Math.Abs(point.X - prior.Point.X) * 2 <= tolerance.Width &&
                Math.Abs(point.Y - prior.Point.Y) * 2 <= tolerance.Height;
            acceptedDown = !skipUp;
            previousClick = null;
            if (skipUp) return;
        }
        if (message.Msg == LeftUp)
        {
            if (skipUp)
            {
                skipUp = false;
                return;
            }
            if (acceptedDown && ClientRectangle.Contains(PointToClient(Cursor.Position)))
                previousClick = (Environment.TickCount64, Cursor.Position);
            acceptedDown = false;
        }
        base.WndProc(ref message);
    }
}
