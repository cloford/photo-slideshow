using System.Text.Json;

namespace PhotoSlideshow;

internal sealed record Options
{
    public int Seconds { get; set; } = 5;
    public bool FromBeginning { get; set; }
    public bool ReserveBarSpace { get; set; }
    public bool BarAtTop { get; set; }
    public bool ClockVisible { get; set; }
    public bool AnalogClock { get; set; }
    public bool ClockAtLeft { get; set; }
}

internal sealed record Favorite(string SourceKind, string SourceID, string PhotoID, DateTimeOffset Added,
    DateTimeOffset Modified, int PixelWidth, int PixelHeight);

internal sealed class UserData
{
    public Options Settings { get; set; } = new();
    public string? Folder { get; set; }
    public Dictionary<string, string> LastByFolder { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public List<Favorite> Favorites { get; set; } = [];
}

internal sealed class Store
{
    private readonly string path;
    public bool CanSave { get; private set; } = true;

    public Store(string path) => this.path = path;

    public UserData Read()
    {
        try
        {
            var data = JsonSerializer.Deserialize<UserData>(File.ReadAllText(path))
                ?? throw new JsonException();
            data.LastByFolder = new(data.LastByFolder, StringComparer.OrdinalIgnoreCase);
            data.Settings.Seconds = Math.Clamp(data.Settings.Seconds, 1, 300);
            return data;
        }
        catch (FileNotFoundException) { return new(); }
        catch (DirectoryNotFoundException) { return new(); }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException
                                      or ArgumentException or NullReferenceException)
        {
            CanSave = false;
            return new();
        }
    }

    public bool Save(UserData value)
    {
        if (!CanSave) return false;
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(temporary, JsonSerializer.Serialize(value));
            File.Move(temporary, path, overwrite: true);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(temporary); }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
            return false;
        }
    }
}

internal sealed record PhotoFile(string ID, string FullPath, DateTime Modified);

internal static class FolderSource
{
    public const string Kind = "windows-folder";
    private static readonly HashSet<string> Extensions = new(
        [".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff"], StringComparer.OrdinalIgnoreCase);

    public static PhotoFile[] Scan(string folder) => Directory.EnumerateFiles(folder)
        .Where(path => Extensions.Contains(Path.GetExtension(path)))
        .Select(path => new PhotoFile(Path.GetFileName(path), path, File.GetLastWriteTimeUtc(path)))
        .OrderBy(photo => photo.Modified).ThenBy(photo => photo.ID, StringComparer.OrdinalIgnoreCase).ToArray();

    public static int StartIndex(PhotoFile[] files, string? previous, bool fromBeginning)
    {
        if (files.Length == 0) return -1;
        if (fromBeginning || previous is null) return 0;
        int found = Array.FindIndex(files, x => StringComparer.OrdinalIgnoreCase.Equals(x.ID, previous));
        return (found + 1) % files.Length;
    }
}
