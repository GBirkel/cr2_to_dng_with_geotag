#!/usr/local/bin/python

import os, sys, re
import getopt
import shutil
import subprocess
import gpxpy
import json
import hashlib

#
# Customize before using:
#

api_seekrit = 'CHANGE THIS'
route_upload_url = "https://mile42.net/wp-json/ptws/v1/route/create"

chart_output_folder = "/Users/gbirkel/Documents/Travel/GPS"	# For generating map+graph pages


# Support function to look for files on a given path
def route_upload_via_curl(route_id, route_body):
	tmp_out_path = os.path.join(chart_output_folder, 'temp_route_upload.txt')
	to = open(tmp_out_path, "w")
	to.write(route_body)
	to.close()

	curl_command = 'curl -F id=\"' + route_id + '\" -F route=@' + tmp_out_path + ' -F key=\"' + api_seekrit + '\" ' + route_upload_url
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

	if not os.path.isdir(chart_output_folder):
		print "Cannot find folder chart_output_folder: " + chart_output_folder + " ."
		exit()

	tmp_in_path = os.path.join(chart_output_folder, 'route_gallery.json')
	with open(tmp_in_path, 'r') as t_file_handle:
		tdata = json.load(t_file_handle)

	# To upload the whole set:
	#for rt in tdata['a']:
	#	route_upload_via_curl(rt[0], rt[1])

	rt = tdata['a'][upload_index-1]
	route_upload_via_curl(rt[0], rt[1])

	exit()

if __name__ == "__main__":
   main(sys.argv[1:])
