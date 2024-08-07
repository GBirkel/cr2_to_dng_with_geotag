#!/Applications/Xcode.app/Contents/Developer/usr/bin/python3

import os, sys, re
import getopt
import shutil
import subprocess
import gpxpy
import json
from common_utils import *

# We can't upload route recordings directly from the route gallery web page,
# since it runs afoul of a security restriction in Apache on the server side.
# The problem is this:  Sending all the JSON as a regular multipart form element
# runs afoul of mod_secrurity's "SecRequestBodyInMemoryLimit" value,
# which was set in /dh/apache2/template/etc/mod_sec2/10_modsecurity_crs_10_config.conf
# with the line "SecRequestBodyInMemoryLimit 131072".
# This causes form submissions above a certain size to be rejected no matter what the
# settings are for PHP or Wordpress.
# So instead we use this command-line app to invoke "curl" which sends the data in the
# form of a file upload.  (This is something browsers are not allowed to do without
# actually being handed a file by user interaction, for security reasons.)

#
# Customize config.xml before using!
#


# Support function to upload a given route id and route data
def route_upload_via_curl(config, route_id, route_body):
	tmp_out_path = os.path.join(config['chart_output_folder'], 'temp_route_upload.txt')
	to = open(tmp_out_path, "w")
	to.write(route_body)
	to.close()

	curl_command = 'curl -F id=\"' + route_id + '\" -F route=@' + tmp_out_path + ' -F key=\"' + config['api_seekrit'] + '\" ' + config['route_upload_url']
	print curl_command

	try:
		route_up_out = subprocess.check_output(curl_command, shell=True)
		print route_up_out
	except subprocess.CalledProcessError:
		print "Error uploading!"
	os.remove(tmp_out_path)


def main(argv):
	upload_index = 0
	try:
		opts, args = getopt.getopt(argv,"hi:",["index="])
	except getopt.GetoptError:
		print 'Route_Uploader.sh -i <index of route to upload>'
		sys.exit(2)
	for opt, arg in opts:
		if opt == '-h':
			print 'Route_Uploader.sh -i <index of route to upload>'
			sys.exit()
		elif opt in ("-i", "--index"):
			upload_index = int(float(arg))
	if upload_index < 1:
		print 'Index to upload must be greater than 0'
		sys.exit(2)
	print 'Index to upload is ', upload_index

	config = read_config()
	if config is None:
		print('Error reading your config.xml file!')
		sys.exit(2)

	if not os.path.isdir(config['chart_output_folder']):
		print "Cannot find folder chart_output_folder: " + config['chart_output_folder'] + " ."
		exit()

	tmp_in_path = os.path.join(config['chart_output_folder'], 'route_gallery.json')
	with open(tmp_in_path, 'r') as t_file_handle:
		tdata = json.load(t_file_handle)

	# To upload the whole set:
	#for rt in tdata['a']:
	#	route_upload_via_curl(config, rt[0], rt[1])

	rt = tdata['a'][upload_index-1]
	route_upload_via_curl(config, rt[0], rt[1])

	exit()

if __name__ == "__main__":
   main(sys.argv[1:])
