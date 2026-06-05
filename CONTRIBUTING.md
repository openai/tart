# Contributing to Tart

Table of Contents
-----------------

- [How to Build](#how-to-build)
- [How to Create an Issue/Enhancement](#how-to-create-an-issueenhancement)
- [Style Guidelines](#style-guidelines)
- [Pull Requests](#Pull-Requests)

## How to Build

1. Fork the repository to your own GitHub account
2. Clone the forked repository to your local machine
3. If using Xcode, use from Xcode 15 or newer
4. Run ./scripts/run-signed.sh from the root of your repository

```bash
./scripts/run-signed.sh list
```
## How to Create an Issue/Enhancement

1. Go to the [Issue page](https://github.com/openai/tart/issues) of the repository
2. Click on the "New Issue" button
3. Provide a descriptive title and detailed description of the issue or enhancement you're suggesting
4. Submit the issue

## Style Guidelines

1. Code should follow camel case
2. Code should follow [SwiftFormat](https://github.com/nicklockwood/SwiftFormat#swift-package-manager-plugin) guidelines. You can auto-format the code by running the following command:

```bash
swift package plugin --allow-writing-to-package-directory swiftformat --cache ignore .
```

## Pull Requests

1. Provide a detailed description of the changes you made in the pull request
2. Wait for pull request to be reviewed 
3. Make adjustments if necessary
