# cr2_to_dng_with_geotag
Python script to find CR2 files on a media card and convert them to DNG, adding geotag information from GPX files on the way.  Only compatible with MacOS but perhaps it can serve as a reference for others developing on other platforms.

This script does the following:
1. Look for a media card (by looking for a specific path)
2. Locate CR2 picture files on the media card
3. Read the capture date, and the flag indicating GPS data present, from each image
4. Make a filename prefix based on the capture date
5. If a DNG image with the same filename and the same capture date exists in a target folder, ignore the image
6. Look for GPX data files from a GPS in a given folder
7. If no GPS data is present in the image, attempt to geotag it using the GPX files
8. Convert the image to Adobe DNG format and copy it to a given target folder
9. Move the original image to a given 'processed' folder (should be on the media card itself) 

Before using:

* `brew install exiftool`
* `pip install gpxpy`
* Download and install Adobe DNG Converter (https://supportdownloads.adobe.com/detail.jsp?ftpID=6319)

References:

* http://wwwimages.adobe.com/www.adobe.com/content/dam/acom/en/products/photoshop/pdfs/dng_commandline.pdf
* https://www.awaresystems.be/imaging/tiff/tifftags/privateifd/exif.html
* https://sno.phy.queensu.ca/~phil/exiftool/geotag.html
* https://www.sno.phy.queensu.ca/~phil/exiftool/faq.html
* https://github.com/guinslym/pyexifinfo
* https://github.com/tkrajina/gpxpy