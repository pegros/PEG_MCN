# ![Logo](/media/Logo.png) &nbsp; SFPEG **MCN** Components

## Introduction

This package contains a set of tools to extend standard **Marketing Cloud Next**
(alias **MCN**) standard functionalities.

These components were built as contributions or examples for former and ongoing Advisory assignments by 
[Pierre-Emmanuel Gros](https://github.com/pegros). 


## Repository Content

This repository contains a whole set of tools dedicated to **Data360** management:
* the **[sfpegMcnDmoSegmentSync](/help/sfpegMcnDmoSegmentSync.md)** schedulable Apex feature


## Installation

ℹ️ As the **ConnectApi** Apex class induces multiple implicit dependencies requiring **Data360**
specific features on scratch Orgs, it is currently impossible to distribute the content of this
repository as an **unlocked package**.

⚠️ **Data360** should be active on your Org when you deploy this package and applicable
permissions granted to your user.

The following two options are therefore available for package installation:
* **Git** and **SF CLI** Deployment
* **Quick Direct Deploy** button


### **Git** and **SF CLI** Deployment

To retrieve the SFDX project, you may simply execute a git clone from the GitHub repository.
```
git clone git@github.com:pegros/PEG_DC.git
```

Via SFDX you may then deploy it on you Org
```
sfdx force:source:deploy -u <yourOrgAlias> -w 10 --verbose -p force-app
```

### Quick Direct Deploy

For a quick and easy deployment, you may alternatively use the following deploy button
leveraging the **[GitHub Salesforce Deploy Tool](https://github.com/afawcett/githubsfdeploy)**
implemented by [Andrew Fawcett](https://andyinthecloud.com/2013/09/24/deploy-direct-from-github-to-salesforce/).

To deploy only the whole package to your Org, you may use the following button.

<a href="https://githubsfdeploy.herokuapp.com?ref=master">
  <img alt="Deploy Package to Salesforce"
       src="https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/deploy.png">
</a>


## Release Notes

ℹ️ As this repository is not distributed as **unlocked package**, there is no real
package version. This section however summarizes the timeline and contents of the main
evolutions made.

ℹ️ First versions included metadata now moved to the **[PEG_LIST_DC](https://github.com/pegros/PEG_LIST_DC)**
package to remove dependencies with the **[PEG_LIST](https://github.com/pegros/PEG_LIST)** package.

### November 2026

First version of the package.
* Transfer of the **[sfpegMcnDmoSegmentSync](/help/sfpegMcnDmoSegmentSync.md)** Apex 
schedulable feature to automatically generate Data360 segments out of an input DMO.


