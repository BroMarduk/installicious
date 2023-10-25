#!/bin/bash

# Make scripts runable
chmod 755 installicious.sh
chmod 755 dependencies/*.sh
chmod 755 installers/*.sh
chmod 755 scripts/*.sh

# Copy all scripts to installation folder
sudo cp -r ~/installicious /etc

# Switch to installation folder and run installicious.
cd /etc/installicious
sudo bash /etc/installicious/installicious.sh
