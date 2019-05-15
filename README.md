# Canon RAW to DNG, with geotag gap-filling, a.k.a. cr2_to_dng_with_geotag

This is a Python script that does the following:

* Import Canon Raw image files (CR2 files) from a media card and convert them to DNG along the way.
* Pull track data from a Garmin Edg 500 or similar device, converting it to GPX along the way.
* Use the GPX data to geotag the DNG files, taking time zone into account.
* If there is geolocation data already in the DNG from the camera, leave it as-is.
* Create an HTML page with a gallery of the GPS routes mapped onto maps from Mapbox using Leaflet, and an upload button to send each route to a Wordpress blog.  (Note, this functionality is badly documented and relies on [my WordPress customizations plugin] (https://github.com/GBirkel/ptws_wordpress_customizations) so you will need to tinker with it to make it work.)

## Why this exists

I own a Canon EOS 5D Mark IV, which supposedly has set-and-forget geotagging, but the GPS is not very strong and will forget where it is when the camera is powered down.  So I carry around a Garmin Edge 500 as a backup, which is tiny, more accurate, and lasts all day.  This script combines data from the two.

I recommend creating an Automator action to run this script, so you can just plug in the media card and click the action.

This script is only compatible with MacOS but perhaps it can serve as a reference for others developing on other platforms.

***

## Actions performed by the script, in detail

1. Check for required tools/folders.
2. Look for a media card (by looking for a specific volume) and locate CR2 image files on it.
3. Look for a Garmin volume and locate FIT data files on it.

If image files are present on a card:

4. Modify the filename to show the capture date from the EXIF tag.
5. Check if a DNG image with the same filename and the same capture date exists in the target folder, and skip if so.
6. Convert the image to DNG, into target folder.
7. Move the image to an "archived" folder on the media card.

If GPS data files are present on a device:

8. Convert them to GPX, auto-splitting the activities if there is a 4-hour gap.
9. Rename the original files to flag that they were processed.
10. Create an HTML gallery page with each activity plotted on a map.

If there are DNG files in the target folder, from this run or an earlier one:

11. Find any that are missing EXIF geotag data.
12. Read in all GPX data files, from this run or an earlier one.
13. If any of the track times overlap the image time, geotag the image with a point between the nearest two points.

***

## Before using:

* `brew install exiftool`
* `brew install gpsbabel`
* `pip install gpxpy`
* Download and install Adobe DNG Converter (https://supportdownloads.adobe.com/detail.jsp?ftpID=6319)

***

### About Time Zones:

Canon 5DS Mk IV firmware prior to 1.1.2 does not embed enough EXIF info for exiftool to extract the time zone directly.  But, it does provide an extended `-TimeZone` tag that we can read and use to construct an equivalent string ourselves.  Newer firmware corrects this.

* Canon firmware 1.0.4 SubSecCreateDate tag example: "`2018:06:03 16:44:52.81`"
* Canon firmware 1.1.2 SubSecCreateDate tag example: "`2018:06:04 00:47:16.69-07:00`"

This script deals with CR2 files from either kind of firmware, but nevertheless, you should [upgrade your Mk IV](https://www.usa.canon.com/internet/portal/us/home/support/details/cameras/dslr/eos-5d-mark-iv?subtab=downloads-firmware) if you haven't already.

***

#### References:

* http://wwwimages.adobe.com/www.adobe.com/content/dam/acom/en/products/photoshop/pdfs/dng_commandline.pdf
* https://www.awaresystems.be/imaging/tiff/tifftags/privateifd/exif.html
* https://sno.phy.queensu.ca/~phil/exiftool/geotag.html
* https://www.sno.phy.queensu.ca/~phil/exiftool/faq.html
* https://github.com/guinslym/pyexifinfo
* https://github.com/tkrajina/gpxpy
