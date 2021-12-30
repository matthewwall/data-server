server {
  listen 80 default_server;
  listen [::]:80 default_server;

  root /var/www/html;
  index index.html;

  server_name _;

  location / {
    try_files $uri $uri/ =404;
  }

  include /etc/nginx/sub.d/*.sub;
}
