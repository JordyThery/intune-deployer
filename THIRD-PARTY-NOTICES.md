# Third-party notices

Intune Deployer is MIT licensed (see LICENSE). It includes the following
project, which is distributed under its own licence.

## Microsoft Authentication Library for iOS and macOS (MSAL)

- Author: Microsoft Corporation
- Repository: https://github.com/AzureAD/microsoft-authentication-library-for-objc
- Version: 2.16.0 (commit 8dfe5bf), through JTKit's JTKitMSAL, which pins it exactly

Intune Deployer uses MSAL to sign in to Entra ID and get access to Microsoft
Graph. MSAL is used unmodified.

### Licence

The licence below is copied unchanged from MSAL's `LICENSE` file at version 2.16.0.

```
MIT License

Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
