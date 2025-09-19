#!/bin/bash
sudo apt-get update -y
sudo apt-get install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx
echo "<h1>Hello from nginx on $(hostname) (private)</h1>" > /var/www/html/index.html
sudo systemctl restart nginx
