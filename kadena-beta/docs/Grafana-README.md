(OSX is also assumed here for alternate OS instructions see Kadena-README.md)

# Using Grafana with Kadena

## Instalation required
`brew install prometheus`

`brew install grafana`

## Start the Kadena demo
The instructions that follow assume your current directory is the Kadena root directory.

`$ tmux`

`$ bin/osx/start.sh`

Hit `return` when the command `./kadenaclient.sh` appears at the prompt in the left window.

To exit the demo, run `exit`. To exit tmux, run `tmux kill-session`.

## Start Prometheus
Start a new terminal session and enter:

`$ cd YOUR_KADENA_DIRECTORY`

`$ prometheus --config.file=static/monitor/prometheus.yml`

## Verfify Prometheus is running
Open a browser to the url http://localhost:9090

Select one of the metrics from the dropdown list to the right of the execute button (e.g. cpu_load1)

Click the Execute button, then select the Graph tab below.

Inside the graph tab, hit the minus button until the text changes from 1h to 5m. Hopefully you will see a graph with 4 different colored lines.

## Start Grafana
Open another terminal window and enter:

`brew services start grafana`

As needed, you can also use the commands:

`brew services stop grafana`

`brew services restart grafana`

## Using the Grafana GUI
Open a browser to the url http://localhost:3000

At the bottom of the left hand side of the screen, right above the help '?' there is a button that lets you login.

Enter `admin` as both the username and password

There should now be additional icons on the left side of the screen.  Click the gear icon and select data sources.

Click the button "+ Add data sources"

Give the new data source a name in the name field and then select the following settings:

Name: kadena

Type: Prometheus

URL: http://localhost:9090

Access: proxy

Auth: (leave all 5 boxes unchecked)

Advanced HTTP Setttings:

    Whitelisted cookies (leave blank)

    Scrape Interval: 5s

  Click the "Save & Test" button.  You should now see "Data source is working" displayed above the "Save & Test" button.

## Import Kadena Dashboard

Click on the "+" icon, then "Import"

Click on "Upload .json File"

Load "static/monitor/grafana-dashboard.json" from your Kadena directory.

In the following "Options" screen, set "kadena" (which refers to the desired data source) to kadena, from the dropdown.

Click "Import".

## Create a New Dashboard

Hover over the "+" symbol on the left, then underneath "Create" select "Dashboard".

Under New Panel, select Graph.

While the mouse is over the (empty) graph, hit the 'e' key.

Above the graph and to the right you will see a time duration displayed (e.g. "Last 6 hours")
Click this button and select "Last 5 minutes"

Change these settings underneath the graph:

Data source: (select the one you just created)

Next to the letter "A", type the name of one of the metrics from the Prometheus drop-down list (e.g., cpu_load1)

Waaaaaaay on the right side of the sceen click the little eye icon so the graph is displayed.

Hopefully you should now see data in the graph.

Additional metrics can be added next to the letters B, C, etc. if desiered.

Select the General tab, and replace the text "Panel Title" with something more meaningful.

Finally, select the blue arrow in the upper right to return to the dashboard.

On the upper right corner of the dashboard, also set the duration to "last 5 minutes", set "Refreshing every" to 5s and hit the Apply button

If desired, you can now click the "Add panel" button at the top right (white graph with an orange + sign) to add additional panels to this dashboard.
