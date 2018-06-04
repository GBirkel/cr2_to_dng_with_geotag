# Canon RAW to DNG, with geotag gap-filling, a.k.a. cr2_to_dng_with_geotag

This is a Python script to find Canon Raw image files (CR2 files) on a media card and convert them to DNG, adding geotag information from GPX files on the way, ONLY if the given image does not already contain geotag data from the camera itself.

I own a Canon EOS 5D Mark IV, which supposedly has set-and-forget geotagging, but the GPS is not very strong and will forget where it is when the camera is powered down.  So I carry around a Garmin Edge 500 as a backup, which is tiny, more accurate, and lasts all day.  I use another script to convert the files from the Edge 500 into GPX format, and this script to convert my images to DNG and geotag the ones that the camera didn't tag.  Rather than delete the images from the card once converting them, the script moves them to an "archive" folder elsewhere on the card to hide them from other programs.  Media cards are huge these days; why not keep the originals around in case something goes wrong?

I recommend creating an Automator action to run this script, so you can just plug in the media card and click the action.

This script does the following:

1. Check for required tools
2. Verify that needed folders are present
3. Look for a media card (by looking for a specific volume)
4. Locate CR2 image files on the media card

If image files are present:

5. Make a filename prefix based on the capture date in the EXIF tag in the image
6. Check if a DNG image with the same filename and the same capture date exists in the target folder and skip the image if so
7. Convert the image to DNG, placing it in the target folder
8. Move the image to an "archived" folder on the media card, using the new filename

If there are DNG files in the target folder, from this run or an earlier one:

9. Find any that are missing EXIF geotag data 
10. Look for GPX data files from a GPS in a given folder
11. Check if any GPX data overlaps with the capture time of any images
12. If so, geotag the image

The idea is to make this script usable in several situations:
* You want to read images off your media card, but don't want to waste the time and space converting them to DNG in a separate step.
* You've pulled GPS data from some other device and want to use it when the camera itself didn't geotag.  (Can happen when your GPS system hasn't booted up fully and/or you power down between shots.)
* You've pulled GPS data from a device and want to tag images that you copied off the card earlier.
* You've copied the images but forgot to pull the GPS first.  (Just run the script again and it will do the right thing.) 

This script is only compatible with MacOS but perhaps it can serve as a reference for others developing on other platforms.  I have tried to avoid most Python-isms in the code to leave it relatively adaptable to other languages.

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