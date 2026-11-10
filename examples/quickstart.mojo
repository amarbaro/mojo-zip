"""Write an archive to a file, read it back, check it: the README example with a real file."""
from zipfile import ZipReader, ZipWriter, ZIP_DEFLATED


def main() raises:
    var path = String(".work/quickstart.zip")
    var w = ZipWriter.create(path, ZIP_DEFLATED, 6)
    var text = "mojo-zip writes and reads zip archives without any C library. " * 20
    w.writestr("notes/readme.txt", text.as_bytes())
    w.mkdir("notes/empty")
    w.set_comment("quickstart".as_bytes())
    w.close()
    var z = ZipReader.open(path)
    for n in z.namelist():
        print(n)
    var back = z.read("notes/readme.txt")
    if len(back) != text.byte_length() or z.testzip():
        raise Error("quickstart: round trip failed")
    print("ok", len(back), "bytes from", z.getinfo("notes/readme.txt").compress_size, "compressed")
